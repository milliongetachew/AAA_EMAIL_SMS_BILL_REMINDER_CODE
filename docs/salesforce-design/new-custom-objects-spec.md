# New Custom Objects Specification — Membership Communications Migration

Every object/field below is **new** — none of it exists in the real org yet
(confirmed against `data-dictionary-reference.md`, the field-level audit of
the actual org). This is the metadata that needs to be created before the
Apex scaffold in `force-app/main/default/classes/` can compile and run.
Field names, types, and purposes are taken directly from how the scaffold
already references them — this document doesn't invent anything beyond
what the code already assumes.

Everything else this migration touches (`Order`, `OrderItem`, `Asset`,
`Account`/Person Account, `Campaign_Code__c`, `Campaign_Action__c`) already
exists in the real org — see `data-dictionary-reference.md`. Only the four
things below need to be built.

## 1. `Correspondence_Log__c` (Custom Object)

**Purpose**: timestamped audit trail of every SMS/Push/Email/Letter
correspondence attempt — replaces `MD300MA`'s correspondence-history
logging and functionally replaces the `EMS_WORK_CAU`/`EMS_WORK_LETTER`
queue tables. Named deliberately to avoid colliding with the *existing*
`Asset.Correspondence__c` multipicklist field, which this object
complements rather than replaces (see `high-level-design.md` §6 for why
both are used together). Written by `CorrespondenceLogger.flush()`.

| Field API Name | Label | Type | Required | Description |
|---|---|---|---|---|
| `Related_Asset__c` | Related Asset | Lookup(`Asset`) | No | The membership Asset this correspondence relates to |
| `Related_Account__c` | Related Account | Lookup(`Account`) | No | The Person Account (member) this correspondence was sent to — named `Related_Account__c`, not `Related_Contact__c`, since the member is an Account in this org's model |
| `Channel__c` | Channel | Picklist | Yes | Values: `SMS`, `PUSH`, `EMAIL`, `LETTER` |
| `Correspondence_Type_Code__c` | Correspondence Type Code | Text(20) | No | Either a legacy-shaped 3-digit code (e.g. `'639'`, `'768'`, `'868'`, `'668'`, `'168'` — matching `Asset.Correspondence__c`'s existing 216 values) or a template code (e.g. `'CARD_DECLINE'`, `'MD58SYNC'`, `'MD58TERR'`) |
| `Status__c` | Status | Picklist | Yes | Values: `SENT`, `FAILED`, `SUPPRESSED`, `SKIPPED` |
| `Sent_Date__c` | Sent Date | Date/Time | No | Timestamp the entry was logged (set to `Datetime.now()` at flush time) |
| `Source_Program__c` | Source Program | Text(20) | No | Legacy program traceability label, e.g. `'MD021EX'`, `'MD058CB'`, `'MD572EM'` |
| `Error_Message__c` | Error Message | Long Text Area (255+) | No | Populated when `Status__c = FAILED` |

## 2. `Eft_Cau_Reject__c` (Custom Object — staging/inbound)

**Purpose**: staging object for inbound EFT card-auto-update reject
records — replaces the `CAUCCREJ` flat file `MD058CB` used to read row by
row. Populated by inbound integration (Platform Event or Apex REST from
the EFT/middleware layer, per `high-level-design.md` §4); processed and
marked done by `EftReconciliationBatch`.

| Field API Name | Label | Type | Required | Description |
|---|---|---|---|---|
| `Club_Code__c` | Club Code | Text | No | Club identifier from the reject record |
| `Membership_Number__c` | Membership Number | Text | No | Member's check-digit membership number, used to resolve the related Asset |
| `Old_Card_Last_Four__c` | Old Card Last 4 Digits | Text(4) | No | Last 4 digits of the card that failed auto-update |
| `Old_Card_Expiration__c` | Old Card Expiration | Date | No | Expiration date of the failed card |
| `Related_Asset__c` | Related Asset | Lookup(`Asset`) | No | The membership Asset this reject applies to — expected to be resolved by the inbound integration before the batch runs, not by `EftReconciliationBatch` itself |
| `Processed__c` | Processed | Checkbox (default `false`) | Yes | Set `true` once `EftReconciliationBatch` has processed this row. `EftReconciliationBatch.start()` queries `WHERE Processed__c = false`, making this the sole idempotency/re-run-safety mechanism replacing `MD058CB`'s mainframe checkpoint/restart logic — see `high-level-design.md` §6 for the resulting semantic change (at-least-once, not exactly-once). |

## 3. `Card_Decline_Event__e` (Platform Event)

**Purpose**: real-time card-decline notification — replaces Finance
manually populating the `EMS_WORK_CCREJ` DB2 work table that `MD572EM`
used to drain. Published by middleware or a payment-gateway webhook relay
(exact publisher **not yet resolved** — see `high-level-design.md` §4
"Billing/Payment gap"); consumed by `CardDeclineDunningHandler` via a
Platform Event trigger (the trigger itself is not included in this
classes-only scaffold — see below).

| Field API Name | Label | Type | Required | Description |
|---|---|---|---|---|
| `Membership_Number__c` | Membership Number | Text | Yes | Member's check-digit membership number, used to resolve the Asset (`Asset.Member_Number__c`) |
| `Card_Type__c` | Card Type | Text | No | Card type/brand |
| `Card_Last_Four__c` | Card Last 4 Digits | Text(4) | No | Last 4 digits of the declined card |
| `Card_Expiration__c` | Card Expiration | Date | No | Expiration date of the declined card |

**Not included in the current scaffold — still needs to be written**: the
actual `trigger CardDeclineEventTrigger on Card_Decline_Event__e (after
insert) { CardDeclineDunningHandler.handleEvents(Trigger.new); }` referenced
in `CardDeclineDunningHandler`'s class header.

## 4. `Renewal_Notification_Rule__mdt` (Custom Metadata Type)

**Purpose**: replaces `MD699BR` (club business rules), the hard-coded
campaign-code whitelist in `MD022EC`, and the per-program day-offset/
consent/channel differences across the whole `MD021EX`/`MD022*` family.
One record per legacy program variant, traceable via `Source_Program__c`,
so a single `MembershipRenewalNotificationBatch` class can serve all six
programs by loading the applicable rule instead of needing one Apex class
per COBOL program. Fully specified already in `high-level-design.md` §3 —
reproduced here for completeness:

| Field API Name | Type | Purpose |
|---|---|---|
| `Source_Program__c` | Text | Traceability label, e.g. `'MD021EX'`, `'MD022EC'` |
| `Active__c` | Checkbox | Enable/disable a rule without a deployment |
| `Club_Code__c` | Text (semicolon-delimited, blank = all clubs) | Club scoping |
| `Campaign_Codes__c` | Text (semicolon-delimited, blank = no restriction) | Supplementary rule-level campaign-code restriction — layered on top of, not a replacement for, the real `Campaign_Code__c` object query |
| `Billing_Event_Codes__c` | Text (semicolon-delimited) | Qualifying billing-event codes — **unresolved pending the Billing/Payment gap**, see `high-level-design.md` §1/§6 |
| `Exclude_Bill_Plan_Types__c` | Text (comma-delimited) | Bill-plan exclusions, evaluated against `Asset.Bill_Plan__c` |
| `Exclude_Bill_Cycles__c` | Text (comma-delimited) | Bill-cycle exclusions — no confirmed "bill cycle" field exists on `Asset`; unresolved |
| `Day_Offset__c` | Number | Days added/subtracted for target-date computation |
| `Date_Formula__c` | Picklist: `SIMPLE_OFFSET`, `OFFSET_PLUS_ONE_YEAR`, `FIXED_MINUS_77` | Which date-math pattern to apply |
| `Requires_SMS_Consent__c` | Checkbox | Whether SMS requires `Account.Consent_for_SMS__c = true` |
| `Requires_Push__c` | Checkbox | Whether this rule also produces a Push notification |
| `Requires_Amount_Due_Gt_Zero__c` | Checkbox | Whether a nonzero amount due is required — **depends on the Billing/Payment gap** |
| `Requires_No_Payment_In_Transit__c` | Checkbox | Whether a pending payment suppresses the send — **depends on the Billing/Payment gap** |
| `Bill_Plan_Filter__c` | Text | e.g. `'AM'` for manually-billed-only cursors |

## Also needed: two new fields on the *existing* `Asset` object

These are not new objects, but the scaffold assumes they exist and they
are **not** part of the real org (not in `data-dictionary-reference.md`) —
flagged here so they aren't missed, and flagged as genuinely unresolved
rather than simply "create this field":

| Field API Name | Type | Used by | Status |
|---|---|---|---|
| `Asset.AAA_Join_Year__c` | Number | `CardDeclineDunningHandler.getYearsOfService()` — years of service = expiration year − join year | Unconfirmed placeholder. Before creating this field, confirm where the join-year data itself would come from — creating an empty field solves nothing if no upstream source populates it. |
| `Asset.Next_Bill_Plan_Type__c` | Text | `EftReconciliationBatch`'s "next billing-cycle bill plan" check (replaces `8500-CHECK-BILLPLN-NXTEVT`) | Unconfirmed placeholder — no "next cycle" field of any kind exists anywhere in the data-dictionary audit. This check may never fire in practice until a real data source is identified. |

## Summary: what to actually build, in order

1. `Renewal_Notification_Rule__mdt` (no dependencies — build first)
2. `Correspondence_Log__c` (depends on `Asset` and `Account`, both already real)
3. `Eft_Cau_Reject__c` (depends on `Asset`)
4. `Card_Decline_Event__e` + its trigger (no object dependencies, but its
   publisher is still an open question per the Billing/Payment gap)
5. The two `Asset` fields above — **only after** confirming a real data
   source exists for each; do not create them speculatively.
