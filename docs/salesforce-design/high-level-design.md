# Revenue Cloud High-Level Design — Membership Renewal / Billing Communication Migration

Target platform: **Salesforce Revenue Cloud** (CPQ managed package `SBQQ`, Billing
managed package `blng`, plus standard objects `Product2`, `Order`, `OrderItem`,
`Asset`, `Contract`, `Account`, `Contact`).

Source system: the 10 IBM Enterprise COBOL batch programs documented in
`docs/cobol-legacy/` (see that folder's `README.md` for the full program
inventory and cross-program relationships). This document assumes that
documentation as ground truth and does not re-derive program behavior from
source.

> **Scaffold disclaimer**: Deliverable 3 (`force-app/main/default/classes/`)
> is a **design scaffold**, not compiled or tested production code. Method
> signatures, control flow, and inline comments tying logic back to specific
> COBOL paragraphs are intended to guide a real implementation sprint, not to
> be deployed as-is. Object/field API names referenced throughout (both
> standard Billing/CPQ managed-package fields and the custom objects/Custom
> Metadata Types proposed here) **must be validated against the target org's
> actual Revenue Cloud edition and configuration** before use — `blng` and
> `SBQQ` field API names vary meaningfully across package versions, and the
> custom objects proposed below (`Correspondence__c`, `Eft_Cau_Reject__c`,
> `Renewal_Notification_Rule__mdt`, `Card_Decline_Event__e`) do not exist yet
> and would need to be created via metadata before any of this scaffold could
> compile.

## 1. Architecture Overview

The legacy pipeline is a set of nightly batch jobs that each (a) select a
population of members from DB2 membership tables or an upstream
work/extract file, (b) apply eligibility gates (payment-in-transit, SMS
consent, amount due, campaign code, billing event), and (c) write a
flat-file extract consumed by a downstream SMS gateway, mobile push
service, or EBIZ/EIP email processor. Two programs (`MD058CB`, `MD572EM`)
additionally drain a DB2 "work table" that an upstream system (EFT,
Finance) populates as its own hand-off mechanism.

Revenue Cloud replaces each of these DB2 structures with a live,
transactional object model plus asynchronous Apex in place of nightly JCL:

| Legacy structure | Revenue Cloud replacement |
|---|---|
| `MBRSHP_HOUSEHOLD` (club + household, bill plan) | `Account` (household) with custom fields for club code and bill-plan type; `blng__BillingAccount__c` for the actual payment/billing relationship |
| `MBR_INFO` / `MEMBER` (individual member) | `Contact`, related to the household `Account` |
| `MBR_PRD_DTL` (membership product detail: term dates, bill plan, paid flag) | `Asset` representing the membership subscription, linked to a `Contract` and `Product2` (the membership product); renewal-term/current-term expiration dates become custom date fields on `Asset` |
| `MBRSHP_NEXT_EVENT` (next billing event code — renewal, late-pay, decline, etc.) | A combination of `blng__Invoice__c` / `blng__Payment__c` status transitions and an `Order`/amendment record for the upcoming renewal; billing-event codes become derived from Billing object status rather than a separate event table |
| `EMS_WORK_CAU`, `EMS_WORK_LETTER` (legacy letter/print queues) | Replaced by direct, synchronous notification generation (no queue table) triggered by Batch/Queueable Apex, logged to a new `Correspondence__c` object instead of being staged for a separate print/extract job |
| `EMS_WORK_CCREJ` (Finance-populated credit-card-decline work table) | A `blng__Payment__c` record transitioning to a Declined/Failed status, surfaced via a Platform Event (`Card_Decline_Event__e`) published by middleware or a `blng__Payment__c` trigger |
| `CAUCCREJ` file (EFT card-auto-update reject feed) | A staging custom object `Eft_Cau_Reject__c`, populated by inbound integration (Platform Event or Apex REST from the EFT/middleware layer), processed by `EftReconciliationBatch` |
| Flat-file SMS/Push/Email extracts (`OSMSFILE`, `OPSHFILE`, `MD134OP`, `MD572O1`, `OUTSMS`/`OUTPSH`/`OUTEML`) | Direct outbound callouts from Apex to a notification gateway (SMS/push/email provider) via External Services + Named Credential — no intermediate file, no separate downstream pickup job |
| JCL scheduling / SYSIN parameters (interval days, club lists) | `Schedulable` Apex + Custom Metadata Type records (`Renewal_Notification_Rule__mdt`) — parameters become declarative, editable-without-deployment configuration, matching the spirit of the COBOL programs that already externalized some of this to `MD699BR` business rules |
| `MD930BR` (get processing date) | `System.today()` / `Datetime.now()` — no subroutine call needed |
| `MD999CK` (club+member → 16-digit check-digit membership number) | A formula field or invocable Apex utility on `Asset`, `Membership_Number__c`, computed the same way (deterministic transform), or — if the check-digit algorithm is itself external — a callout to the same legacy service during a transition period |
| `MC501BCD`/`MC502BCD` (customer name/email/phone lookup) | Native `Contact` fields (`FirstName`, `Email`, `MobilePhone`) — no lookup subroutine needed once data lives natively in Salesforce |
| `MC556BR` (SMS consent check) | A `Contact` consent field (`SMS_Opt_In__c`) or, if the org has one, Salesforce's native consent-management data model |
| `FN435BT` (payment-in-transit check) | A query against `blng__Payment__c` for records in a "Processing"/"Pending" status against the member's `blng__BillingAccount__c` |
| `MD610BR` (amount currently due) | `blng__Invoice__c.blng__Balance__c` (or an aggregated balance across open invoices) on the `blng__BillingAccount__c` |
| `MD699BR` (club business rules: day offsets, exclusions, club abbreviations) | `Renewal_Notification_Rule__mdt` (see §3) |
| `MD607BR` (letter/correspondence-type decision for billing emails) | Folded into `Renewal_Notification_Rule__mdt` / a small rules helper in `BillingEmailQueueable`, since the underlying decision table was not part of the reviewed source and cannot be reproduced exactly |
| `MD300MA` (correspondence-history logging) | `CorrespondenceLogger` Apex class writing to `Correspondence__c` |

## 2. Object Model Mapping Table

| Legacy concept (COBOL program / DB2 table) | Revenue Cloud object | Notes |
|---|---|---|
| Household / club (`MBRSHP_HOUSEHOLD`) | `Account` (Household) | Club code becomes a custom field `Club_Code__c` on `Account`; may also map to a `blng__BillingAccount__c` for payment terms |
| Member (`MBR_INFO`/`MEMBER`) | `Contact` | Role `'00'` (primary), used as the filter in nearly every cursor in the legacy set, maps to the Contact being the `AccountContactRelation` primary / the Asset's `Contact` lookup |
| Membership (`MBR_PRD_DTL`) | `Asset` under a `Contract`, linked to `Product2` (the membership product) | `Asset.Membership_Number__c`, `Asset.Bill_Plan_Type__c` (AC/AM/MP), `Asset.Current_Term_Expiration_Date__c`, `Asset.Renewal_Term_Expiration_Date__c` |
| Renewal (implicit: `CUR_TERM_EXP_D < REN_TERM_EXP_D`) | Asset renewal — either an `Order` amendment against the `Asset`'s `Contract` (CPQ renewal opportunity/quote) or simply the Asset's own renewal-term date fields, depending on whether the org models renewals as new Orders | Flagged for validation: whether renewals are modeled as Order amendments (full CPQ renewal process) or just date-field updates on the Asset depends on org configuration not visible from the COBOL source |
| Bill Plan (`FK_BILL_PLAN_TYP_C` = AC/AM/MP) | `blng__PaymentMethod__c` type + `blng__BillingAccount__c` billing preferences | AC (autopay) → an active default `blng__PaymentMethod__c` of type Card/ACH; AM (manual) → no default payment method / invoice-pay; MP (monthly pay) → `blng__BillingAccount__c` billing frequency = Monthly |
| Next billing event (`MBRSHP_NEXT_EVENT.FK_MBR_BILL_EVENT`) | Derived from `blng__Invoice__c`/`blng__Payment__c` status + a computed "next event" indicator, OR a lightweight custom field `Asset.Next_Bill_Event_Code__c` maintained by a Billing-side trigger/flow if Billing's native statuses don't cleanly cover every legacy event code (e.g. `'75'` = CC decline, `'04'/'40'/'41'/'55'-'59'` = various late-pay states) | The legacy event-code taxonomy is finer-grained than Billing's native payment/invoice status model; a mapping table (part of `Renewal_Notification_Rule__mdt`, see §3) is needed to translate |
| Campaign code eligibility (`MD022EC`'s whitelist) | Custom Metadata Type driving eligibility criteria — see `Renewal_Notification_Rule__mdt` (§3); campaign code itself could live as `Asset.Campaign_Code__c` or come from a Marketing Cloud/Campaign Member relationship | The legacy whitelist was hard-coded and extended club-by-club over 18 months; CMDT records replace this without requiring a deployment per new campaign code |
| Correspondence log (`MD300MA` / `EMS_WORK_CAU` / `EMS_WORK_LETTER`) | New custom object `Correspondence__c`, related to `Asset` and `Contact` | Fields: `Related_Asset__c`, `Related_Contact__c`, `Channel__c` (SMS/Push/Email/Letter), `Correspondence_Type_Code__c` (preserves legacy codes like `'639'`, `'868'`, `'768'`, `'668'`, `'168'` for audit traceability), `Status__c`, `Sent_Date__c`, `Source_Program__c`, `Error_Message__c` |
| Payment-in-transit (`FN435BT`) | `blng__Payment__c` query, status = Processing/Pending, against the member's `blng__BillingAccount__c` | Field name for "in transit"/processing status must be validated against the installed `blng` package version |
| SMS/text consent (`MC556BR`) | `Contact.SMS_Opt_In__c` (custom checkbox) or native consent object if the org has Consent Management enabled | |
| EFT CAU reject file (`MD058CB` input) | `Eft_Cau_Reject__c` (new custom object, staging records from inbound integration) | Replaces the `CAUCCREJ` flat file; see §3 |
| Credit-card decline event (`MD572EM`'s `EMS_WORK_CCREJ`) | `Card_Decline_Event__e` (Platform Event) published when `blng__Payment__c.blng__Status__c` transitions to Declined/Failed | Replaces Finance's manual population of the DB2 work table with a real-time event |
| 16-digit check-digit membership number (`MD999CK`) | `Asset.Membership_Number__c` (formula or Apex-computed at Asset creation) | The check-digit algorithm itself was not part of the reviewed COBOL source (`MD999CK` is called, not defined, in every program) — must be sourced separately before this can be reproduced exactly in Apex |

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
| `Campaign_Codes__c` | Text (semicolon-delimited, blank = no restriction) | Marketing campaign-code whitelist | `MD022EC`'s growing `9000068`…`9000088` list |
| `Billing_Event_Codes__c` | Text (semicolon-delimited) | Qualifying `FK_MBR_BILL_EVENT`-equivalent codes | `MD022EC`/`MD022LP` (`'04','40','41','55'-'59'`), `md022cc` (`'75'`) |
| `Exclude_Bill_Plan_Types__c` | Text (comma-delimited) | Bill-plan exclusions | `MD022EC`/`MD022LP` exclude `'AC','AH'` |
| `Exclude_Bill_Cycles__c` | Text (comma-delimited) | Bill-cycle exclusions | `MD022EC`/`MD022LP` exclude `'IM','MA','NB'` |
| `Day_Offset__c` | Number | Days added/subtracted for target-date computation | `WS-SMS-DAYS` (`MD022EX`, via `MD699BR`), `WS-INTERVAL-DAYS` (`MD022EC`/`MD022LP`/`md022cc`, via SYSIN), hard-coded `13` in `MD021EX` |
| `Date_Formula__c` | Picklist: `SIMPLE_OFFSET`, `OFFSET_PLUS_ONE_YEAR`, `FIXED_MINUS_77` | Which of the (at least) three distinct date-math patterns found in the source to apply | `SIMPLE_OFFSET` = `MD021EX`/`MD022EX`/`MD022ER` (`proc date + N days`); `OFFSET_PLUS_ONE_YEAR` = `MD022EC`/`MD022LP`/`md022cc`'s unusual `(proc date − N days) + 1 year` formula (preserved faithfully — see Ambiguity note below); `FIXED_MINUS_77` = `MD022ZA`'s upstream "-77 day" window (that program did no date math of its own — flagged as not fully portable, see §6) |
| `Requires_SMS_Consent__c` | Checkbox | Whether SMS channel requires `Contact.SMS_Opt_In__c = true` | `MD021EX`/`MD022EX`/`MD022EC`/`MD022LP`/`MD022ZA` = true; `md022cc` = **false** (consent check explicitly removed, MEM-482325 — preserve this distinction deliberately, do not default it to true) |
| `Requires_Push__c` | Checkbox | Whether this rule also produces a Push notification | `MD022ER`/`MD022LP`/`md022cc`/`MD022ZA` = true (Push always independent of SMS consent); `MD021EX`/`MD022EX`/`MD022EC` = false (no Push channel) |
| `Requires_Amount_Due_Gt_Zero__c` | Checkbox | Whether a nonzero amount due is required before sending | `MD022EX`/`MD022ER` = true (`MD610BR` gate); `MD022EC`/`MD022LP`/`md022cc`/`MD022ZA` = false (no `MD610BR` call in source) |
| `Requires_No_Payment_In_Transit__c` | Checkbox | Whether a pending payment suppresses the send | `MD021EX`/`MD022EX` = true; `MD022ER` = **computed but not enforced in source** (flagged ambiguity, preserved as a togglable field rather than silently "fixed"); `MD022EC`/`MD022LP`/`md022cc`/`MD022ZA` = not present in source at all |
| `Bill_Plan_Filter__c` | Text | e.g. `'AM'` for manually-billed-only cursors | `MD021EX`/`MD022EX`/`MD022ER`'s `FK_BILL_PLAN_TYP_C = 'AM'` filter |

## 4. Integration Architecture

### Outbound (SMS / Push / Email)

All outbound channels are unified behind `NotificationGatewayService`
(Deliverable 3), which wraps a single **External Service** definition
(imported from the notification provider's OpenAPI spec) bound to a
**Named Credential** (`Notification_Gateway`). This replaces the pattern
of writing a flat file (`OSMSFILE`, `MD022OP`, `MD572O1`, etc.) for a
downstream job to pick up — Apex calls the provider synchronously (from
Batch Apex's `execute()`, which supports callouts when the class
implements `Database.AllowsCallouts`, or from Queueable Apex).

- **Governor-limit note**: a single Apex transaction is limited to 100
  callouts. Any batch scope that could produce more than 100
  SMS+Push+Email sends per `execute()` invocation must either (a) keep
  batch scope size low enough that per-record callouts stay under 100, or
  (b) switch to a bulk/batched notification-provider API (one callout per
  scope, carrying many recipients) if the provider supports it. This is
  called out again in the class-level comments in `NotificationGatewayService`.

### Inbound (payment decline / EFT reject)

- **Card decline** (replaces `EMS_WORK_CCREJ`, `MD572EM`'s input):
  modeled as a Platform Event, `Card_Decline_Event__e`, published either
  by a trigger on `blng__Payment__c` when its status transitions to
  Declined/Failed, or by middleware relaying the payment gateway's
  webhook directly. `CardDeclineDunningHandler` subscribes (via a
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
| `CorrespondenceLogger` | Helper (no interface) | `MD300MA`, and functionally replaces `EMS_WORK_CAU`/`EMS_WORK_LETTER` as the system-of-record for "what was sent to whom" |
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
`MembershipRenewalNotificationBatch`, once the "-77 days before
expiration" eligibility window is confirmed and expressed as a SOQL
filter on `Asset.Current_Term_Expiration_Date__c` — flagged in §6 as
needing business confirmation rather than being guessed at.

## 6. Explicit Flags for Validation

- **`blng`/`SBQQ` field API names are illustrative, not confirmed.** Every
  reference to `blng__BillingAccount__c`, `blng__Payment__c`,
  `blng__Invoice__c`, `blng__PaymentMethod__c`, and their fields
  (`blng__Status__c`, `blng__Balance__c`, etc.) in this document and in
  the Deliverable 3 scaffold must be checked against the org's installed
  Billing package version before implementation. Field names differ
  between Billing releases.
- **Renewal modeling (Order amendment vs. Asset date fields)** is not
  determinable from the COBOL source, which only ever reads/compares term
  expiration dates — it never shows how a renewal is *created*. Confirm
  with the business whether Revenue Cloud renewals should go through the
  full CPQ renewal-quote/Order-amendment process or a lighter-weight
  Asset field update, before finalizing `Asset` vs. `Order` responsibility
  boundaries.
- **`MD999CK`'s check-digit algorithm** is called, never defined, in every
  reviewed program — it cannot be reproduced in Apex without the original
  algorithm or a decision to keep calling the legacy service during
  transition (e.g., via a callout to a wrapped mainframe service, if one
  is exposed).
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
- **`MD022ZA`'s "-77 days" eligibility window** is not implemented as a
  concrete SOQL filter in this scaffold (see §5) because the actual
  upstream filtering logic (`MD145A`) was outside the reviewed file set.
- **Billing-event-code taxonomy** (`FK_MBR_BILL_EVENT` values like `'75'`,
  `'04'`, `'40'`/`'41'`, `'55'`-`'59'`) has no confirmed mapping onto
  Billing's native invoice/payment status model; `Billing_Event_Codes__c`
  on the CMDT is a placeholder pending that mapping exercise.
