# Revenue Cloud High-Level Design — Membership Renewal / Billing Communication Migration

> **Ground truth**: `docs/salesforce-design/data-dictionary-reference.md` is
> a field-level audit of the actual target org (real automation, real
> record counts, cross-checked against live flows/Apex) and **supersedes
> every `blng__`/`SBQQ` field reference in this document and in the
> Deliverable 3 Apex scaffold**. Read that document first. Where this
> document still calls something an open question (chiefly: Billing/
> Payment), that reflects a genuine gap in the audit's scope, not a detail
> this document is free to invent around.

Target platform: **native Salesforce Revenue Lifecycle Management** —
standard `Order`/`OrderItem`/`Asset`, assetized via the `revenue_o2aflows`
managed package's Order-to-Asset flow — plus the standard `Account` object
used in **Person Account** mode (`IsPersonAccount = true`) for individual
members. This is confirmed to be **not** the CPQ managed package (`SBQQ`)
and **not** the Billing managed package (`blng`). An earlier draft of this
document assumed those packages were in use and modeled members as a
separate `Contact`; the data-dictionary audit corrected both assumptions,
and every `blng__`/`SBQQ`/`Contact` reference below has been replaced with
the real object/field it actually corresponds to, or explicitly flagged as
an open question where no confirmed replacement exists (principally: no
Billing/Payment object of any kind appears anywhere in the audited org).

Source system: the 10 IBM Enterprise COBOL batch programs documented in
`docs/cobol-legacy/` (see that folder's `README.md` for the full program
inventory and cross-program relationships). This document assumes that
documentation as ground truth for COBOL behavior and does not re-derive
program behavior from source; it assumes `data-dictionary-reference.md` as
ground truth for the target org's schema and live automation.

> **Scaffold disclaimer**: Deliverable 3 (`force-app/main/default/classes/`)
> is a **design scaffold**, not compiled or tested production code. Method
> signatures, control flow, and inline comments tying logic back to specific
> COBOL paragraphs are intended to guide a real implementation sprint, not to
> be deployed as-is. Object/field API names below now reflect the real,
> field-verified schema in `data-dictionary-reference.md` wherever that
> document confirms one. The one area it does **not** cover — Billing/
> Payment (amount due, payment-in-transit, card-decline status) — remains a
> genuinely open question and is marked as such throughout rather than
> filled in with a `blng__`-shaped guess. The custom objects/CMDT proposed
> below (`Correspondence_Log__c`, `Eft_Cau_Reject__c`,
> `Renewal_Notification_Rule__mdt`, `Card_Decline_Event__e`) do not exist yet
> in the org and would need to be created via metadata before any of this
> scaffold could compile — this is distinct from the fields/objects this
> document cites from the data dictionary, which **do** already exist.

## 1. Architecture Overview

The legacy pipeline is a set of nightly batch jobs that each (a) select a
population of members from DB2 membership tables or an upstream
work/extract file, (b) apply eligibility gates (payment-in-transit, SMS
consent, amount due, campaign code, billing event), and (c) write a
flat-file extract consumed by a downstream SMS gateway, mobile push
service, or EBIZ/EIP email processor. Two programs (`MD058CB`, `MD572EM`)
additionally drain a DB2 "work table" that an upstream system (EFT,
Finance) populates as its own hand-off mechanism.

Revenue Lifecycle Management replaces each of these DB2 structures with a
live, transactional object model plus asynchronous Apex in place of nightly
JCL. Every row below is grounded in `data-dictionary-reference.md`; where
that document does not cover a legacy concept, this table says so plainly
instead of inventing a `blng__`/`SBQQ` field to fill the gap.

| Legacy structure | Revenue Lifecycle Management replacement |
|---|---|
| `MBRSHP_HOUSEHOLD` (club + household, bill plan) | The household is the **Person Account** itself in this org's model (see "Person Account" note below) — `Account.Club_Code__c` (real picklist, authoritative club source) and `Account.Member_Type__c` (household role: Primary/Associate/Dependent/Donor/MSO). No confirmed billing-account/bill-plan object exists at the household level — see "Billing/Payment gap" below. |
| `MBR_INFO` / `MEMBER` (individual member) | **Person Account** fields directly on `Account` (`PersonEmail`, `PersonMobilePhone`, `PersonHomePhone`, and per-channel deliverability picklists `Email_Status__pc`/`Mobile_Status__pc`/`Home_Phone_Status__pc`) — **not** a separate `Contact`. The household is modeled through `AccountContactRelation`, not a Contact-to-Account child relationship. |
| `MBR_PRD_DTL` (membership product detail: term dates, bill plan, paid flag) | `Asset` (the membership subscription), assetized from `Order`/`OrderItem` by the platform-internal `revenue_o2aflows__o2aFlow` (async, after-commit, on Order Activation). Real fields: `Asset.Member_Number__c` (on the `ProductCode='60'` parent asset — **53% blank, verified**), `Asset.Bill_Plan__c` (formula, derives a code like `AC` from `Billing_Frequency__c`+`Payment_Method__c`+`Autopay__c`), `Asset.CurrentLifecycleEndDate`/`LifecycleEndDate` (standard, platform-set — the closest available stand-in for "current term expiration"/"renewal term expiration"; exact semantic parity with those two legacy fields is **not confirmed**, flagged in §6). `Asset.Status` is **null on 97% of Assets, verified** — do not gate eligibility on it. |
| `MBRSHP_NEXT_EVENT` (next billing event code — renewal, late-pay, decline, etc.) | **No confirmed replacement.** None of the 7 audited objects contains a billing-event/next-event field. This billing-event taxonomy (`'75'` = CC decline, `'04'/'40'/'41'/'55'-'59'` = late-pay states) remains fully unresolved — see "Billing/Payment gap" below. |
| `EMS_WORK_CAU`, `EMS_WORK_LETTER` (legacy letter/print queues) | Direct, synchronous notification generation (no queue table) triggered by Batch/Queueable Apex, recorded via **two complementary signals** (deliberate choice, not a default — see §6): (1) `Asset.Correspondence__c`, the **existing** 216-value multipicklist already used in this org for exactly this purpose (correspondence codes accompanying cards/bills), updated as a lightweight, at-a-glance signal; and (2) a **new** custom object `Correspondence_Log__c` (deliberately *not* named `Correspondence__c`, to avoid colliding in name with the existing Asset field) providing full timestamped audit history — something a multipicklist cannot represent. |
| `EMS_WORK_CCREJ` (Finance-populated credit-card-decline work table) | **Partially unresolved.** A Platform Event (`Card_Decline_Event__e`) published by middleware or a payment-gateway webhook relay is still the recommended shape, but its trigger condition ("a payment record transitions to Declined/Failed") assumed a `blng__Payment__c`-style object the data dictionary does not confirm exists — see "Billing/Payment gap" below. |
| `CAUCCREJ` file (EFT card-auto-update reject feed) | A staging custom object `Eft_Cau_Reject__c`, populated by inbound integration (Platform Event or Apex REST from the EFT/middleware layer), processed by `EftReconciliationBatch`. Not covered by the data-dictionary audit's 7 object sheets, so this remains a net-new proposal rather than a real-org confirmation. |
| Flat-file SMS/Push/Email extracts (`OSMSFILE`, `OPSHFILE`, `MD134OP`, `MD572O1`, `OUTSMS`/`OUTPSH`/`OUTEML`) | **Corrected** (see §4 changelog note): the same flat-file hand-off pattern, not a live provider API. Apex accumulates one row per notification in memory over the run, then uploads one file per channel per run to **MOVEit** (managed file transfer) via HTTPS/Named Credential, landing in a shared folder in `.txt` or `.csv` format (varies by legacy program — see §4) for the same downstream SMS gateway / push service / EBIZ-EIP email processor to pick up, exactly as it did with `OSMSFILE`/`OUTSMS`/etc. MOVEit Automation is expected to apply PGP encryption server-side after upload; Apex does not do PGP |
| JCL scheduling / SYSIN parameters (interval days, club lists) | `Schedulable` Apex + Custom Metadata Type records (`Renewal_Notification_Rule__mdt`) — parameters become declarative, editable-without-deployment configuration, matching the spirit of the COBOL programs that already externalized some of this to `MD699BR` business rules |
| `MD930BR` (get processing date) | `System.today()` / `Datetime.now()` — no subroutine call needed |
| `MD999CK` (club+member → check-digit membership number) | **Already solved in the target org — not a design gap.** The Apex class `RVNMembershipNo`, invoked from the Asset-side `Generate_Membership_Number` flow (after-save Create+Update, entry criterion `ProductCode='60' AND Member_Number__c blank AND AccountId not null`), populates `Asset.Member_Number__c` and `Account.Member_Number__c`. The remaining work is a **data-quality backfill**, not an algorithm to reproduce: **21 of 40 Membership assets (53%) are still blank, verified.** |
| `MC501BCD`/`MC502BCD` (customer name/email/phone lookup) | Native **Person Account** fields (`FirstName`, `LastName`, `PersonEmail`, `PersonMobilePhone`) — no lookup subroutine needed. Use `Email_Status__pc`/`Mobile_Status__pc` (Valid/Invalid/Transactional Call Only/Declined) as the deliverability gate instead of a null check — a materially better signal than the legacy validity-code check it replaces. |
| `MC556BR` (SMS consent check) | `Account.Consent_for_SMS__c` (real, confirmed boolean field) — checked directly on the Person Account, since the member **is** the Account in this org's model. |
| `FN435BT` (payment-in-transit check) | **Unresolved.** No Billing/Payment object exists anywhere in the data dictionary audit — see "Billing/Payment gap" below. This needs its own investigation, not a `blng__Payment__c` guess. |
| `MD610BR` (amount currently due) | **Unresolved**, same "Billing/Payment gap" as `FN435BT` above. |
| `MD699BR` (club business rules: day offsets, exclusions, club abbreviations) | `Renewal_Notification_Rule__mdt` (see §3) |
| `MD607BR` (letter/correspondence-type decision for billing emails) | Folded into `Renewal_Notification_Rule__mdt` / a small rules helper in `BillingEmailQueueable`, since the underlying decision table was not part of the reviewed source and cannot be reproduced exactly |
| `MD300MA` (correspondence-history logging) | `CorrespondenceLogger` Apex class, writing to **both** `Correspondence_Log__c` (new object, full audit trail) and `Asset.Correspondence__c` (existing multipicklist, lightweight signal) — see the correspondence-log row above and §6. |
| `MD022EC`'s hard-coded campaign-code whitelist | The **real** `Campaign_Code__c`/`Campaign_Action__c` objects (already exist — `Club_Code__c`, `Status__c`, `Effective_Date__c`/`Expiration_Date__c`, `Pricing_Type__c`, `AutoPay_Required__c`, etc.), queried directly instead of a CMDT-only whitelist. **Important**: these objects currently have **zero automation** — nothing in the org enforces them today, so this migration is the **first** thing to actually enforce campaign eligibility at the platform level, not a replication of an existing enforcement mechanism. See §2 and §6. |

### Billing/Payment gap (applies to several rows above)

None of the 7 objects in `data-dictionary-reference.md` (`Order`,
`OrderItem`, `Asset`, `Account`, `Person Account`, `Campaign_Code__c`,
`Campaign_Action__c`) is an Invoice, Payment, or Billing Account/Treatment
object. This is a **genuine open question**, not a naming detail:
`FN435BT` (payment-in-transit), `MD610BR` (amount due), and the
`EMS_WORK_CCREJ`/card-decline billing-status trigger all depend on a
billing/payment data source this audit did not cover. Do not assume
`blng__` objects exist in this org just because the audit didn't rule them
out — the Deliverable 3 scaffold keeps its `blng__Payment__c`/
`blng__Invoice__c` references exactly as illustrative placeholders
(unchanged, not re-guessed with different field names) pending a separate
investigation into whether Salesforce Billing — or some other billing
system entirely — is actually in use.

### Person Account model (applies throughout)

The member is a **Person Account** (`Account` with `IsPersonAccount =
true`), not a Contact related to a business Account. Every `Contact`
reference in an earlier draft of this document and the Deliverable 3
scaffold (`Contact.Email`, `Contact.MobilePhone`, `Contact.SMS_Opt_In__c`,
`Asset.ContactId`, etc.) is corrected below to the real relationship:
`Asset.AccountId` points directly at the Person Account — there is no
separate Contact lookup on `Asset` the way a business-Account/Contact
scaffold would assume.

## 2. Object Model Mapping Table

| Legacy concept (COBOL program / DB2 table) | Real Salesforce object/field | Notes |
|---|---|---|
| Household / club (`MBRSHP_HOUSEHOLD`) | `Account` (Person Account) | `Account.Club_Code__c` (real picklist, 9 values — the authoritative club source; read-only, nothing writes it via automation). No confirmed billing-account object for payment terms — see §1 "Billing/Payment gap". |
| Member (`MBR_INFO`/`MEMBER`) | The **Person Account itself** (`IsPersonAccount = true`), not a Contact | Role `'00'` (primary), used as the filter in nearly every cursor in the legacy set, maps to `Account.Member_Type__c = 'Primary Member'`, enforced by `RTF_Validate_Primary_Member_on_Account` (one Primary Member per household, validation-only). The household is modeled via `AccountContactRelation`, not a Contact-to-Account child relationship. |
| Membership (`MBR_PRD_DTL`) | `Asset`, assetized from `Order`/`OrderItem` by `revenue_o2aflows__o2aFlow` | `Asset.Member_Number__c` (53% blank, verified — see §1), `Asset.Bill_Plan__c` (formula, e.g. `AC`), `Asset.CurrentLifecycleEndDate`/`LifecycleEndDate` (standard, platform-set — best available stand-in for the two legacy term-expiration dates; exact semantic match **not confirmed**, see §6). `Asset.ProductCode = '60'` identifies the Membership parent asset (`CurrentQuantity = 0`, a container); `'01'`/`'80'` are seen on component assets holding `CurrentQuantity = 1`. |
| Renewal (implicit: `CUR_TERM_EXP_D < REN_TERM_EXP_D`) | Not determinable from the data dictionary either — `OriginalActionType` (Add/Amend/Cancel/No Change/Renew/Transfer) is stamped by Revenue Cloud's `initiateAmendment`/`initiateRenewal` invocable Apex from the Amend-Renew-and-Cancel screen flow, suggesting renewals **are** modeled as Order amendments, but this needs explicit business confirmation before `Asset` vs. `Order` responsibility boundaries are finalized (see §6). |
| Bill Plan (`FK_BILL_PLAN_TYP_C` = AC/AM/MP) | `Asset.Bill_Plan__c` (real formula field), derived from `Billing_Frequency__c` + `Payment_Method__c` + `Autopay__c` | Always current (it's a formula), unlike the legacy stored code. No confirmed default-payment-method or billing-account object exists to represent "AM = invoice-pay" — see §1 "Billing/Payment gap". |
| Next billing event (`MBRSHP_NEXT_EVENT.FK_MBR_BILL_EVENT`) | **No confirmed replacement** — none of the 7 audited objects has a next-event/billing-event field | The legacy event-code taxonomy (`'75'` CC decline, `'04'/'40'/'41'/'55'-'59'` late-pay states) has no home in this org's confirmed schema; `Billing_Event_Codes__c` on `Renewal_Notification_Rule__mdt` (§3) remains a placeholder pending a real billing/payment data source. |
| Campaign code eligibility (`MD022EC`'s whitelist) | The **real** `Campaign_Code__c` object — `Club_Code__c`, `Status__c` (Active/Draft/Rejected/Scheduled/Retired), `Effective_Date__c`/`Expiration_Date__c`, `Pricing_Type__c`, `AutoPay_Required__c`, `Billing_Type__c`, `Code_Category__c` — plus its master-detail child `Campaign_Action__c` for discount mechanics | This object already exists and matches `MD022EC`'s intent closely, but has **zero automation today** (no flow, trigger, or validation rule) — it's hand-maintained reference data, not currently enforced anywhere. This migration is the first thing to actually enforce it. `OrderItem.Campaign_Code_Applied__c` stores the code's **name** (e.g. `PO65%`), not its Id — matches `Campaign_Code__c.Campaign_Code_Name__c`. **Gap**: `Asset` does not carry a campaign-code identifier field forward from the Order, so resolving "which campaign code applies to this member's renewal" from the Asset alone is not currently possible — see §6. |
| Correspondence log (`MD300MA` / `EMS_WORK_CAU` / `EMS_WORK_LETTER`) | **Two signals, deliberately used together** — see §6 for why this is not a single-answer choice | (1) `Asset.Correspondence__c` — **existing** 216-value multipicklist already used for this exact purpose in this org; codes get added as a lightweight, queryable-on-the-record signal, preserving legacy codes like `'639'`, `'868'`, `'768'`, `'668'`, `'168'`. (2) New object `Correspondence_Log__c` (named to avoid colliding with the existing `Asset.Correspondence__c` field) with `Related_Asset__c`, `Related_Account__c` (Person Account lookup — named `Related_Account__c`, not `Related_Contact__c`, since the member is an Account, not a Contact, in this org's model), `Channel__c`, `Correspondence_Type_Code__c`, `Status__c`, `Sent_Date__c`, `Source_Program__c`, `Error_Message__c` — full timestamped audit history, which the multipicklist structurally cannot provide. |
| Payment-in-transit (`FN435BT`) | **Unresolved** — no Billing/Payment object in the data dictionary | See §1 "Billing/Payment gap"; the scaffold's `blng__Payment__c` reference is left as an unchanged, explicitly-flagged placeholder, not replaced with a different guess. |
| SMS/text consent (`MC556BR`) | `Account.Consent_for_SMS__c` (real, confirmed boolean field) | Checked on the Person Account directly. For email suppression specifically, prefer the standard `PersonHasOptedOutOfEmail` over any custom consent field. |
| EFT CAU reject file (`MD058CB` input) | `Eft_Cau_Reject__c` (new custom object, staging records from inbound integration) | Replaces the `CAUCCREJ` flat file; see §3. Not covered by the data-dictionary audit, so remains a net-new proposal. |
| Credit-card decline event (`MD572EM`'s `EMS_WORK_CCREJ`) | `Card_Decline_Event__e` (Platform Event), intended to be published when a payment record transitions to Declined/Failed | The triggering payment-status object is unconfirmed — see §1 "Billing/Payment gap". Replaces Finance's manual population of the DB2 work table with a real-time event once that gap is resolved. |
| Out-of-territory member (`MD058CB`'s lodge-code check, `8600-GET-LODGE-TYPE`) | `Account.Out_Of_Territory__c` (real, confirmed boolean field) | Replaces any guessed lodge-code equivalent — this is the actual field the business uses for this branch today. |
| Check-digit membership number (`MD999CK`) | `Asset.Member_Number__c` / `Account.Member_Number__c`, populated by the real Apex `RVNMembershipNo` via the `Generate_Membership_Number` flow | **Solved, not a design gap** — see §1. Remaining work is backfilling the 53%/47%-blank population, not reproducing an algorithm. |

## 3. Custom Metadata Type: `Renewal_Notification_Rule__mdt`

This single CMDT replaces the combined behavior of `MD699BR` (club business
rules), the hard-coded campaign-code whitelists in `MD022EC`, and the
per-program day-offset/consent/channel differences across the whole
`MD021EX`/`MD022*` family. Each CMDT record represents one "legacy program
variant" (traceable via `Source_Program__c`), so the same generic
`MembershipRenewalNotificationBatch` (Deliverable 3) can serve all of them
by loading the applicable rule(s) rather than requiring one Apex class per
COBOL program.

| Field | Type | Purpose | Legacy origin |
|---|---|---|---|
| `Source_Program__c` | Text | Traceability label, e.g. `'MD021EX'`, `'MD022EC'` | n/a (new) |
| `Active__c` | Checkbox | Enable/disable a rule without deployment | n/a (new) |
| `Club_Code__c` | Text (semicolon-delimited, blank = all clubs) | Club scoping | `MD022EC`'s club whitelist; `MD021EX`/`MD022EX` implicitly all clubs |
| `Campaign_Codes__c` | Text (semicolon-delimited, blank = no restriction) | **Supplementary** rule-level campaign-code restriction, layered on top of (not a replacement for) the real `Campaign_Code__c` object query described in §1/§2 — use this field only for a rule-specific narrowing (e.g. "this particular legacy program only ever fired for these codes"), not as the source of truth for whether a code is currently active/eligible | `MD022EC`'s growing `9000068`…`9000088` list |
| `Billing_Event_Codes__c` | Text (semicolon-delimited) | Qualifying `FK_MBR_BILL_EVENT`-equivalent codes | `MD022EC`/`MD022LP` (`'04','40','41','55'-'59'`), `md022cc` (`'75'`) — **doubly unresolved**: the data dictionary confirms no Billing/Payment object exists in this org at all, so there is no field to source these event codes from today, not just an unconfirmed field name (see §1 "Billing/Payment gap") |
| `Exclude_Bill_Plan_Types__c` | Text (comma-delimited) | Bill-plan exclusions | `MD022EC`/`MD022LP` exclude `'AC','AH'` — evaluated against `Asset.Bill_Plan__c` (real formula field, replaces the placeholder `Bill_Plan_Type__c`) |
| `Exclude_Bill_Cycles__c` | Text (comma-delimited) | Bill-cycle exclusions | `MD022EC`/`MD022LP` exclude `'IM','MA','NB'` — no confirmed "bill cycle" field exists on `Asset` in the data dictionary; remains unresolved alongside the Billing/Payment gap |
| `Day_Offset__c` | Number | Days added/subtracted for target-date computation | `WS-SMS-DAYS` (`MD022EX`, via `MD699BR`), `WS-INTERVAL-DAYS` (`MD022EC`/`MD022LP`/`md022cc`, via SYSIN), hard-coded `13` in `MD021EX` |
| `Date_Formula__c` | Picklist: `SIMPLE_OFFSET`, `OFFSET_PLUS_ONE_YEAR`, `FIXED_MINUS_77` | Which of the (at least) three distinct date-math patterns found in the source to apply | `SIMPLE_OFFSET` = `MD021EX`/`MD022EX`/`MD022ER` (`proc date + N days`); `OFFSET_PLUS_ONE_YEAR` = `MD022EC`/`MD022LP`/`md022cc`'s unusual `(proc date − N days) + 1 year` formula (preserved faithfully — see Ambiguity note below); `FIXED_MINUS_77` = `MD022ZA`'s upstream "-77 day" window (that program did no date math of its own — flagged as not fully portable, see §6) |
| `Requires_SMS_Consent__c` | Checkbox | Whether SMS channel requires `Account.Consent_for_SMS__c = true` (the Person Account, real confirmed field — replaces the placeholder `Contact.SMS_Opt_In__c`) | `MD021EX`/`MD022EX`/`MD022EC`/`MD022LP`/`MD022ZA` = true; `md022cc` = **false** (consent check explicitly removed, MEM-482325 — preserve this distinction deliberately, do not default it to true) |
| `Requires_Push__c` | Checkbox | Whether this rule also produces a Push notification | `MD022ER`/`MD022LP`/`md022cc`/`MD022ZA` = true (Push always independent of SMS consent); `MD021EX`/`MD022EX`/`MD022EC` = false (no Push channel) |
| `Requires_Amount_Due_Gt_Zero__c` | Checkbox | Whether a nonzero amount due is required before sending | `MD022EX`/`MD022ER` = true (`MD610BR` gate); `MD022EC`/`MD022LP`/`md022cc`/`MD022ZA` = false (no `MD610BR` call in source) |
| `Requires_No_Payment_In_Transit__c` | Checkbox | Whether a pending payment suppresses the send | `MD021EX`/`MD022EX` = true; `MD022ER` = **computed but not enforced in source** (flagged ambiguity, preserved as a togglable field rather than silently "fixed"); `MD022EC`/`MD022LP`/`md022cc`/`MD022ZA` = not present in source at all |
| `Bill_Plan_Filter__c` | Text | e.g. `'AM'` for manually-billed-only cursors | `MD021EX`/`MD022EX`/`MD022ER`'s `FK_BILL_PLAN_TYP_C = 'AM'` filter |

## 4. Integration Architecture

### Outbound (SMS / Push / Email)

> **Correction (post-review)**: an earlier version of this document
> described this integration as direct outbound callouts from Apex to a
> notification-provider API (SMS/push/email gateway) via External Services
> + Named Credential, with "no intermediate file, no separate downstream
> pickup job." That was wrong. The actual downstream delivery mechanism —
> for both the legacy COBOL pipeline and its Revenue Cloud replacement — is
> a **flat-file hand-off via MOVEit** (a managed file transfer / MFT
> product): Salesforce/Apex produces a file, and it is delivered from there
> to the actual SMS gateway / push service / EBIZ-EIP email processor,
> exactly as `OSMSFILE`, `OUTSMS`, `MD572O1`, etc. were picked up by a
> separate job in the legacy pipeline. The section below replaces the
> earlier (incorrect) per-message-callout description. **See the second
> correction immediately below** — the "MOVEit delivers it PGP-encrypted"
> detail in this paragraph is itself superseded by real job-configuration
> evidence.

> **Second correction (post-review, real Control-M/AFT job configuration
> confirmed)** — see `docs/salesforce-design/moveit-aft-reference.md` for
> the full evidence this is based on: the paragraph above still described a
> **single-stage** model (Salesforce uploads plaintext, MOVEit PGP-encrypts
> it server-side). Real AFT job screenshots and three real output-file
> samples show the actual pipeline is **two stages**, chained by job
> predecessor, and MOVEit is a relay, not the encrypting system:
> 1. **Stage 1 ("O" job, write-to-staging)** — an AFT job (e.g.
>    `MRD1104O_AFT_PUSH_MEM_ZEROAUTH`) transfers a mainframe dataset to a
>    **local staging path** on a Windows/mainframe-local server (`gid01943`,
>    under `%%PGPTemp.\MRD\...`). The file is **plaintext** at this point.
> 2. **Stage 2 ("E" job, "Encrypted File Transfer Job")** — a separate AFT
>    job (`Required Predecessor` = the Stage 1 job) PGP-encrypts the Stage 1
>    file **client-side, before it ever reaches MOVEit**, then transfers the
>    already-encrypted file to MOVEit (`/users/SMSPUSH/OUTBOUND/`) and
>    deletes the plaintext source.
>
> **MOVEit never sees plaintext and never performs the encryption itself.**
> The observed PGP key (`salesforce-prod-042325-1 (sfmc xfer)`, vendor
> `SalesForce`), combined with SFMC MobileConnect-specific column names in
> the real SMS extract (`SubscriberKey`, `Locale`), make it near-certain the
> **real final destination past MOVEit is Salesforce Marketing Cloud** —
> strongly indicated, not 100% confirmed; worth a direct confirmation with
> whoever owns the SFMC side.
>
> **Consequence for this design**: Salesforce/Apex does not need to
> implement PGP encryption or speak MOVEit's transfer protocol at all. The
> realistic implementation is to plug into the same existing two-stage
> AFT/MOVEit pipeline — i.e. have the Apex-generated extract land wherever
> Stage 1 currently drops its plaintext staging file, or an equivalent new
> drop point the AFT/integration team provisions for Salesforce-originated
> files — and let the existing Stage 2 job carry it the rest of the way.
> **This hand-off mechanism is an explicitly open question, not a resolved
> design**: Apex can only make outbound HTTPS callouts, it cannot write to
> a Windows/mainframe-local file share like `gid01943` directly. Whether the
> real mechanism is an HTTPS endpoint the AFT/integration layer exposes for
> this purpose, or something else entirely, needs confirmation from the
> AFT/MOVEit/integration team before implementation — do not assume a
> specific endpoint shape as fact anywhere below.

> **Third correction (user-confirmed 2026-09-01): MOVEit itself is capable
> of PGP encryption.** This means the Stage 2 "Encrypted File Transfer Job"
> described above may well be MOVEit's own automation engine executing the
> `PUB_SalesForce`-keyed encryption task, not a separate non-MOVEit system —
> Stage 2 could genuinely be "part of MOVEit," not just chained in front of
> it. That makes the most concrete integration path: **Apex uploads a
> plaintext file directly to a MOVEit-exposed HTTPS endpoint via Named
> Credential, and MOVEit's own automation applies PGP encryption and
> forwards the result onward** (very plausibly still to SFMC) — this is now
> the leading candidate for the hand-off mechanism, not just one of several
> equally-uncertain options. **Still open, and still needs a real answer,
> not a guess:** the specific MOVEit endpoint/API shape Salesforce would
> call, what credential/auth it needs, and whether a *new* MOVEit task/
> folder needs to be provisioned for Salesforce-originated files (reusing
> the exact `PUB_SalesForce` task as-is vs. a parallel one) — see
> `moveit-aft-reference.md` for the full framing.

All outbound channels are unified behind `NotificationGatewayService`
(Deliverable 3), which now implements a **queue-then-flush** pattern
mirroring the legacy write-record / close-file pattern:

1. **Queue** — `queueSms()`/`queuePush()`/`queueEmail()` append one row
   per notification to an in-memory, per-channel buffer (replaces a single
   `WRITE SMS-RECORD` / `WRITE PUSH-RECORD` / `WRITE EMAIL-RECORD`). No
   callout happens here.
2. **Flush** — `flush()`, called exactly **once per batch run** (from
   Batch Apex's `finish()`, so a multi-scope run still produces one file
   per channel rather than one per scope; or at the end of a Queueable's
   single `execute()`), assembles each channel's buffered rows into a file
   body and uploads it to MOVEit via **one HTTPS callout per channel**,
   through a Named Credential (replaces `CLOSE OUTPUT-FILE` and the
   downstream job's file pickup).

Two Apex/Salesforce platform constraints shape this design and must be
respected, not worked around:

- **Apex has no native OpenPGP/PGP implementation, and it doesn't need
  one.** `Crypto.encrypt()` / `Crypto.encryptWithManagedIV()` are AES/RSA
  primitives, not the OpenPGP message container format the downstream
  pipeline expects, but PGP encryption is confirmed to already happen
  **outside Apex** — either in the existing Stage 2 "Encrypted File
  Transfer" AFT job, or, per the user-confirmed update (see the third
  correction above and `moveit-aft-reference.md`), plausibly by MOVEit's
  own automation engine running that same Stage 2 task directly. Apex's
  job is only to produce the **plaintext** extract and get it to wherever
  that existing pipeline's input point is; it does not need to implement
  PGP itself either way — whether that input point is a pre-MOVEit staging
  drop or a MOVEit-exposed HTTPS endpoint that MOVEit itself then encrypts
  from is the open hand-off question described in the next bullet.
- **Apex has no SFTP client** — only HTTP(S) callouts (no raw sockets), and
  it cannot write to a Windows/mainframe-local file share the way the
  Stage 1 AFT job does. **UNRESOLVED**: exactly how Apex hands its
  plaintext extract off to the AFT/MOVEit pipeline has not been confirmed.
  Since MOVEit is confirmed capable of PGP encryption itself (see the
  third correction above), a direct HTTPS upload to a MOVEit-exposed
  endpoint — with MOVEit's own automation applying PGP encryption after
  Apex's plaintext upload — is now the leading candidate, not the unlikely
  option it was previously framed as. Whether that reuses the existing
  `PUB_SalesForce` task/endpoint as-is or requires a new one provisioned
  for Salesforce-originated files, what credential/auth it needs, and the
  exact endpoint/API shape all remain unconfirmed and need a real answer
  from the AFT/MOVEit/integration team before implementation;
  `NotificationGatewayService` implements a placeholder HTTPS upload shape
  pending that confirmation — see its class header for details, and do not
  treat that placeholder as a confirmed MOVEit API contract.

**File format**: the legacy programs did not use one consistent flat-file
format — `MD021EX` wrote comma-delimited CSV (`OUT-FILE`/`MD021OP`),
`MD134ML` and `MD572EM` wrote semicolon-delimited text (`MD134OP`,
`MD572O1`), and the `MD022EX`/`MD022ER`/`MD022EC`/`MD022LP`/`md022cc`
(`OSMSFILE`) and `MD058CB` (`OUTSMS`/`OUTPSH`/`OUTEML`) families wrote
fixed-width `PIC X(nnn)` records (see each program's `docs/cobol-legacy/
*.md` for the exact layout). Since the downstream consumer of these files
is **not** changing, the recommended default is to replicate each legacy
program's existing record layout rather than invent a new shape; a clean,
modernized CSV format is a possible future-phase option only once the
downstream consumer itself is revisited. The current scaffold implements
only a generic comma/semicolon delimited writer as a placeholder for the
delimited-format programs (`MD021EX`, `MD134ML`, `MD572EM`); fixed-width
formatting for the `MD022*`/`MD058CB` families is **not yet implemented**
and needs a dedicated formatter built from those programs' copybooks
(`MRD058SF`/`MRD058PF`/`MRD058EF`, etc.) before cutover for those specific
programs.

- **Governor-limit note (revised)**: the old "100 callouts per
  transaction" concern from the per-message-callout design no longer
  applies the same way. Sends are now batched into at most one
  file-upload callout per channel per run, not one callout per record —
  so a batch scope of thousands of rows still produces only a handful of
  callouts total (one per channel actually used, on the single `flush()`
  call), not one per row. The limits to watch instead are heap size (all
  of a run's queued rows are held in memory until `flush()`, which is why
  `MembershipRenewalNotificationBatch` and `EftReconciliationBatch` both
  hold their `NotificationGatewayService` as `Database.Stateful` state
  rather than re-creating it per scope) and the per-callout request body
  size limit (6 MB synchronous / larger via async callouts) if a single
  day's extract could get large. This is called out again in the
  class-level comments in `NotificationGatewayService`.

### Inbound (payment decline / EFT reject)

- **Card decline** (replaces `EMS_WORK_CCREJ`, `MD572EM`'s input):
  modeled as a Platform Event, `Card_Decline_Event__e`. The originally
  proposed trigger condition — "a trigger on `blng__Payment__c` when its
  status transitions to Declined/Failed" — depends on a Billing/Payment
  object the data dictionary does not confirm exists in this org (see §1
  "Billing/Payment gap"); until that is resolved, publishing via
  middleware relaying the payment gateway's webhook directly is the only
  confirmed-feasible path. `CardDeclineDunningHandler` subscribes (via a
  Platform Event trigger, not included in this classes-only scaffold —
  see Deliverable 3 note) and processes events asynchronously.
- **EFT CAU reject** (replaces the `CAUCCREJ` file, `MD058CB`'s input):
  modeled as inbound integration (MuleSoft or direct Apex REST) landing
  rows in the staging object `Eft_Cau_Reject__c` with `Processed__c =
  false`; `EftReconciliationBatch` scopes and processes unprocessed rows.
  A Platform-Event-based design was considered but a staging object is
  preferred here because `MD058CB` has checkpoint/restart semantics (see
  §6) that map more naturally onto a re-runnable Batch Apex job over a
  durable staging table than onto a fire-and-forget event stream.

## 5. Apex Class Inventory

| Class | Type | Replaces (COBOL program(s)) |
|---|---|---|
| `MembershipRenewalNotificationBatch` | `Database.Batchable<SObject>`, `Database.AllowsCallouts`, `Database.Stateful` | `MD021EX`, `MD022EX`, `MD022ER`, `MD022EC`, `MD022LP`, `md022cc` (config-driven via `Renewal_Notification_Rule__mdt`; see §6 for why `MD022ZA` is only partially covered) |
| `MembershipRenewalNotificationScheduler` | `Schedulable` | Replaces the JCL scheduling of the `MD021EX`/`MD022*` nightly jobs |
| `RenewalEligibilityRules` | Helper (no interface) | `MD699BR` (business-rule lookups), the campaign-code gate in `MD022EC`, the billing-event/bill-plan/bill-cycle filters in `MD022EC`/`MD022LP`, `FN435BT` (PIT check equivalent), `MC556BR` (consent check equivalent) |
| `BillingEmailQueueable` | `Queueable`, `Database.AllowsCallouts` | `MD134ML` (including the letter-139 web-self-service suppression rule, INC943560) |
| `CardDeclineDunningHandler` | Queueable-based Platform Event handler | `MD572EM`, calling out to helper methods standing in for `MC501BCD`, `MD999CK`, `MD380MA`, `MD642BR`, `MD699BR`, `MD930BR` |
| `EftReconciliationBatch` | `Database.Batchable<SObject>`, `Database.AllowsCallouts` | `MD058CB`'s core bill-plan reconciliation loop and its 2025 SMS/Push/Email notification behavior |
| `NotificationGatewayService` | Helper (no interface) | Stand-in for all downstream file-consumer systems (SMS gateway, push service, EBIZ/EIP email processor) — used by every class above |
| `CorrespondenceLogger` | Helper (no interface) | `MD300MA`, and functionally replaces `EMS_WORK_CAU`/`EMS_WORK_LETTER` as the system-of-record for "what was sent to whom" — writes to **both** the new `Correspondence_Log__c` object (audit trail) and the existing `Asset.Correspondence__c` multipicklist (lightweight signal); see §1/§2 |
| `MembershipRenewalNotificationBatchTest` | `@isTest` | Tests for `MembershipRenewalNotificationBatch` |
| `MembershipRenewalNotificationSchedulerTest` | `@isTest` | Tests for `MembershipRenewalNotificationScheduler` |
| `RenewalEligibilityRulesTest` | `@isTest` | Tests for `RenewalEligibilityRules` |
| `BillingEmailQueueableTest` | `@isTest` | Tests for `BillingEmailQueueable` |
| `CardDeclineDunningHandlerTest` | `@isTest` | Tests for `CardDeclineDunningHandler` |
| `EftReconciliationBatchTest` | `@isTest` | Tests for `EftReconciliationBatch` |
| `NotificationGatewayServiceTest` | `@isTest` | Tests for `NotificationGatewayService` |
| `CorrespondenceLoggerTest` | `@isTest` | Tests for `CorrespondenceLogger` |

`MD022ZA` is intentionally **not** given a 1:1 batch class. Per its own
documentation, it has no membership-eligibility logic of its own — all
filtering happens in an upstream extract job that was not part of the
reviewed source (`MD145A`, a clone source, is also outside the reviewed
set). Its Revenue Cloud equivalent is a `Renewal_Notification_Rule__mdt`
record (`Date_Formula__c = 'FIXED_MINUS_77'`) processed by the same
`MembershipRenewalNotificationBatch`. **The "-77 days" window itself is
now confirmed real**, not just an inferred name: the real AFT staging
filename for `MD022` SMS INT77
(`TRAN_SMS_MEM_ZEROAUTH_MINUS_77DAYS_%%$DATE..csv`, and its Push
counterpart `TRAN_PUSH_MEM_ZEROAUTH_MINUS_77DAYS_...`, per
`moveit-aft-reference.md`) confirms `-77 days` is the actual production
window, not a documentation artifact. **What remains unresolved** is only
the exact upstream candidate-list filtering logic that populates that
extract (still `MD145A`, still outside the reviewed source, per the
existing caveat below) — the window's identity is resolved, the
eligibility logic that feeds it is not — and, separately, which of
`Asset.CurrentLifecycleEndDate`/`LifecycleEndDate` the `-77 days` should
be measured against (see §6).

## 6. Explicit Flags for Validation

- **No Billing/Payment object exists anywhere in the field-verified data
  dictionary — this is a confirmed gap, not an unconfirmed field name.**
  The org uses native Revenue Lifecycle Management, not the `blng` managed
  package; none of the 7 audited objects (`Order`, `OrderItem`, `Asset`,
  `Account`, `Person Account`, `Campaign_Code__c`, `Campaign_Action__c`) is
  an Invoice, Payment, or Billing Account/Treatment object. Every
  `blng__BillingAccount__c`, `blng__Payment__c`, `blng__Invoice__c`,
  `blng__PaymentMethod__c` reference remaining in the Deliverable 3
  scaffold (`loadPaymentsInTransit`/`loadAmountDue` in
  `MembershipRenewalNotificationBatch` and `CardDeclineDunningHandler`) is
  left as an explicitly-flagged, unchanged placeholder — **do not** treat
  the absence of a ruled-out `blng__` reference as evidence Billing is
  installed, and do not replace these placeholders with a different set of
  guessed field names. `MD610BR` (amount due) and `FN435BT`
  (payment-in-transit) require a separate investigation into what billing/
  payment system (if any) actually backs this org before they can be
  implemented for real.
- **Person Account correction.** An earlier draft of this document and the
  Deliverable 3 scaffold modeled the member as a `Contact` related to a
  business `Account`, including `Asset.ContactId`. The data dictionary
  confirms members are **Person Accounts** (`Account.IsPersonAccount =
  true`); there is no `Asset.ContactId` the way a Contact-based scaffold
  assumes — `Asset.AccountId` points directly at the Person Account.
  `PersonEmail`/`PersonMobilePhone`/`PersonHomePhone` and the deliverability
  picklists `Email_Status__pc`/`Mobile_Status__pc`/`Home_Phone_Status__pc`
  replace every `Contact.Email`/`Contact.MobilePhone` reference. This has
  been corrected throughout Deliverable 3 (see class-level comments there)
  — flagged here as the single most consequential correction in this
  document, since it changes SOQL relationship paths, not just field names.
- **`Campaign_Code__c`/`Campaign_Action__c` have zero automation today —
  this migration is the first enforcement point.** These real objects
  exist and are hand-maintained (25 current codes, all `Status__c =
  'Active'`), but nothing in the org today — no flow, trigger, or
  validation rule — actually applies their discount/eligibility rules to
  an order or renewal. Treat `RenewalEligibilityRules`'s campaign-code gate
  as introducing new, real enforcement, not replicating existing behavior;
  confirm with the business that this is an intended, not accidental,
  behavior change. Separately, **`Asset` does not carry a campaign-code
  identifier field forward from the originating `Order`/`OrderItem`** (only
  campaign *pricing* fields propagate via
  `RT_AssetActionSource_Payment_Method_Propagation`, not the code itself,
  and `OrderItem.ParentOrderItemId`'s bundle hierarchy is lost at
  assetization) — resolving "which campaign code applies to this member's
  renewal" from the Asset alone needs either a new propagated field or a
  traversal back through `AssetActionSource`/`OrderItem`, neither of which
  is implemented in this scaffold.
- **Correspondence design decision: both `Asset.Correspondence__c` (existing
  multipicklist) and a new `Correspondence_Log__c` object are recommended,
  deliberately, not by default.** `Asset.Correspondence__c` already holds
  216 three-digit codes of exactly the kind the legacy programs wrote
  (`'639'`, `'868'`, `'768'`, `'668'`, `'168'`, etc.), so it is a natural,
  low-friction place to record "this type of correspondence is on file for
  this member" — but as a multipicklist it cannot represent *when* a
  specific message was sent, on which channel, with what delivery status,
  or a repeated code sent more than once (e.g. two SMS reminders 30 days
  apart both being `'768'`). A multipicklist collapses all of that into a
  single selected/not-selected value per code. Real audit history (what was
  sent, to whom, when, success/failure) genuinely needs a separate,
  timestamped object — hence `Correspondence_Log__c` (deliberately not
  named `Correspondence__c`, to avoid colliding in name with the existing
  Asset field). `CorrespondenceLogger.flush()` writes to both.
- **The exact MOVEit API/product surface is unconfirmed.** §4's outbound
  design assumes an HTTPS "upload file" callout via Named Credential, but
  whether that is MOVEit Transfer's REST API, a MOVEit Automation task
  trigger, or an integration-platform (e.g. MuleSoft) hop that itself talks
  SFTP/MOVEit on Salesforce's behalf has not been confirmed. The Named
  Credential name, endpoint path, HTTP method, auth scheme, and
  request/response payload shape in `NotificationGatewayService` are all
  placeholders pending that confirmation.
- **The PGP responsibility boundary is assumed, not confirmed.** This
  design assumes MOVEit Automation applies PGP encryption server-side
  after Salesforce uploads a plaintext file — Apex has no native OpenPGP
  implementation and is not expected to produce PGP-encrypted output
  itself. Confirm this is actually how the target MOVEit environment is
  configured before relying on it; if Salesforce is required to hand off
  already-PGP-encrypted content, that requires a different design (a
  middleware hop or AppExchange PGP package), not currently implemented.
- **Per-channel/per-program flat-file layout is only partially
  implemented.** `NotificationGatewayService`'s generic delimited writer
  covers `MD021EX` (CSV), `MD134ML` and `MD572EM` (semicolon-delimited)
  as placeholders; it does not implement the fixed-width `PIC X(nnn)`
  layouts used by the `MD022EX`/`MD022ER`/`MD022EC`/`MD022LP`/`md022cc`
  and `MD058CB` families. Confirm whether the downstream consumer(s) for
  those channels still require byte-identical legacy layouts before
  cutover, and if so, build per-program fixed-width formatters from their
  copybooks.
- **Renewal modeling (Order amendment vs. Asset date fields)** is not
  determinable from the COBOL source, which only ever reads/compares term
  expiration dates — it never shows how a renewal is *created*. Confirm
  with the business whether Revenue Cloud renewals should go through the
  full CPQ renewal-quote/Order-amendment process or a lighter-weight
  Asset field update, before finalizing `Asset` vs. `Order` responsibility
  boundaries.
- **`MD999CK`'s check-digit algorithm — RESOLVED, no longer a flag.** The
  data dictionary confirms a real Apex implementation (`RVNMembershipNo`,
  invoked from the `Generate_Membership_Number` flow) already exists and
  runs in the org, populating `Asset.Member_Number__c` and
  `Account.Member_Number__c`. What remains is a **data-quality backfill**
  (21 of 40 Membership assets, 53%, still blank — verified), not an
  algorithm to source or reproduce. Do not re-derive or re-implement this.
- **The `(processing date − interval) + 1 YEAR` date formula** used by
  `MD022EC`/`MD022LP`/`md022cc` is preserved faithfully in
  `RenewalEligibilityRules` (as `Date_Formula__c = 'OFFSET_PLUS_ONE_YEAR'`)
  because its business rationale is not documented in source. Do not
  "simplify" this to a plain offset without confirming with the business
  that the original formula was itself a bug rather than an intentional
  one-year look-ahead.
- **`md022cc`'s removed SMS consent check (MEM-482325)** is preserved as
  a deliberately different rule (`Requires_SMS_Consent__c = false`) rather
  than normalized to match its siblings — this is a compliance-relevant
  distinction and should be re-confirmed with legal/compliance during
  migration, not silently carried forward or silently "fixed."
- **`MD022ER`'s non-enforced PIT check** (computed but not used to gate
  sends, per that program's documented ambiguity) is modeled as a
  togglable CMDT field rather than assumed to be a bug — needs a business
  decision before the Revenue Cloud rule is finalized.
- **`MD058CB`'s checkpoint/restart and `GO TO`-based deadlock retry**
  (§Ambiguous notes in `md058cb.md`) has no direct Apex equivalent. The
  proposed replacement (§4, staging object + re-runnable Batch Apex) uses
  Salesforce's native per-scope transaction rollback and the batch job's
  natural re-runnability instead of a manual checkpoint mechanism, but
  this changes the failure/retry semantics from the original program and
  should be reviewed against actual operational requirements (e.g., is
  at-least-once vs. exactly-once processing required for CAU rejects?).
- **`MD058CB`'s dormant bill-plan-flip-to-AM logic** (`2210-CHANGE-
  HOUSEHOLD-AM`, etc., disabled since MEM-480905) is **not** included in
  `EftReconciliationBatch`'s scaffold, matching current production
  behavior. Confirm with the business whether this is permanently retired
  before treating its absence here as final.
- **`MD022ZA`'s "-77 days" eligibility window — partially resolved.** The
  window itself is now **confirmed real** (the real AFT staging filename
  for `MD022` SMS/PUSH INT77 is literally
  `TRAN_SMS_MEM_ZEROAUTH_MINUS_77DAYS_...`/
  `TRAN_PUSH_MEM_ZEROAUTH_MINUS_77DAYS_...`, per
  `moveit-aft-reference.md`), so this is no longer an open question about
  whether "-77 days" is a real production value. It is still **not**
  implemented as a concrete SOQL filter in this scaffold (see §5), because
  the actual upstream candidate-list filtering logic that populates the
  extract (`MD145A`) remains outside the reviewed file set — do not treat
  the window's confirmation as resolving that separate, still-open
  eligibility-logic gap.
- **Billing-event-code taxonomy** (`FK_MBR_BILL_EVENT` values like `'75'`,
  `'04'`, `'40'`/`'41'`, `'55'`-`'59'`) has no confirmed mapping onto any
  object in this org — see the Billing/Payment gap above.
  `Billing_Event_Codes__c` on the CMDT is a placeholder pending resolution
  of that larger gap, not just a mapping exercise.
- **Real automation is broken/fragile in ways that must not be silently
  assumed away by this design:**
  - `Asset.Status` is **null on 97% of Assets (184 of 190), verified** —
    do not gate any eligibility check on it being populated. This already
    breaks `Set_Asset_Status_to_Active_if_Unpaid_False` (unreachable, since
    no Asset is ever `Impaired`) and neuters
    `Maintain_Only_One_Membership_On_Account`'s Active/Grace/
    Suspended/Salvage filter in the live org today.
  - `Asset.CLUB_CODE__c` **never fires — verified 0 of 190 Assets
    populated** (its before-save flow tries `$Record.Account.Club_Code__c`,
    a parent traversal unavailable in before-insert context). Use
    `Asset.Club__c` (the working formula field, `TEXT(Account.Club_Code__c)`)
    everywhere this design needs a club code on an Asset — never
    `CLUB_CODE__c`.
  - `Asset.Membership_Tier__c` and `Asset.RV_Motorcyle_Add_On__c` are
    derived by **substring-matching sibling Asset Names** (priority
    Premier > Plus > Classic for tier; `'RV'` substring for the add-on) —
    fragile, name-dependent logic, not a product-attribute lookup. Do not
    build new logic that depends on these being reliable; if tier-based
    eligibility is needed, prefer the input field `OrderItem.Tier__c` or a
    genuine product-attribute source if one exists, and flag the fragility
    to the business rather than silently trusting the derived value.
  - Several Order-side flows this design would otherwise lean on are
    **DRAFT and never activated**: `Set_Order_Type` (meant to derive
    `Order.Type` and drive every `Billing*`/`Shipping*` address-copy-down)
    and the address-copy-down flows themselves. `Order.Type` is
    nonetheless populated on live records — something platform-internal,
    not this flow, is setting it — so do not assume address or Type data
    is being actively maintained by the automation that appears to own it.
  - `Account.Consent_for_SMS__c`, `Account.Out_Of_Territory__c`, and the
    Person Account deliverability picklists have **no automation writing
    them** either (they're hand-maintained/data-migration values per the
    dictionary) — treat them as reliable *inputs* to read, not fields this
    migration can assume are being kept current by some other process.
- **Fields the business has explicitly marked for removal must not be
  designed around**: `Client_ID__c`, `FCC_Response__c`,
  `Lodge_Club_Code__c`, `homePageAccount__c`, `Related_Record_Flag__c`,
  `Updated_By__c` (Account); `Membership__pc`, `Territory__pc` (Person
  Account); `Membership_Price__c`, `SpecialHandlingObj__c` (Asset). None of
  these appear anywhere in this document or the Deliverable 3 scaffold as
  of this correction pass.
