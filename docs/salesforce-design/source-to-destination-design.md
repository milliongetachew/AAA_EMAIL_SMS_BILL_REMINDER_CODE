# Source-to-Destination Design — Membership Communications Migration

High-level view of where member data comes from today, where it's moving to,
and where outbound notifications ultimately land — for the migration of
ACSC's 10 legacy COBOL batch programs to Salesforce Revenue Cloud. This
document sits above `high-level-design.md` (object-level detail),
`data-dictionary-reference.md` (real org schema), and
`moveit-aft-reference.md` (real delivery pipeline); read those for specifics
this document only summarizes.

## The picture

![Source-to-destination diagram: the legacy mainframe track (DB2 tables → COBOL batch programs → flat file) and the target Salesforce track (Revenue Cloud objects → Batch/Queueable Apex → extract file) both feed into the same shared destination pipe — AFT Stage 1 staging, AFT Stage 2 MOVEit encrypt-and-relay, and onward to Salesforce Marketing Cloud. The legacy track's connection to that pipe is solid and confirmed; the target track's connection is dashed and marked as an unresolved open question, since Apex can only make outbound HTTPS calls and cannot write to the pipeline's local staging file share directly.](source-to-destination-diagram.svg)

**The one claim this diagram carries: the migration changes the *source* of
the data, not the *destination* it's delivered to.** Both today's mainframe
and tomorrow's Salesforce org need to reach the same AFT/MOVEit pipe, which
very likely terminates at Salesforce Marketing Cloud. Only one leg of that
picture is still unconfirmed — how Salesforce hands its file to that pipe in
the first place.

## Source (today)

| Layer | What it is | Detail |
|---|---|---|
| Data | DB2 tables | Household, member, product-detail, and event tables read by cursor in each COBOL program — see `docs/cobol-legacy/*.md` for the per-program cursor and field list |
| Processing | 10 COBOL batch programs | `MD021EX`, `MD022EX`/`ER`/`EC`/`LP`/`cc`/`ZA`, `MD134ML`, `MD572EM`, `MD058CB` — full inventory in `docs/cobol-legacy/README.md` |
| Output | One flat file per run per channel | Fixed-width, comma-delimited, or semicolon-delimited depending on the program — see `moveit-aft-reference.md` for the three real, sample-confirmed layouts (SMS/Push, Email, CAU email) |

## Destination (target)

| Layer | What it is | Detail |
|---|---|---|
| Data | Salesforce Revenue Cloud (native Revenue Lifecycle Management) | Standard `Order`/`OrderItem`/`Asset` objects, `Account`/Person Account for members, real custom objects `Campaign_Code__c`/`Campaign_Action__c` — confirmed via a field-level org audit, see `data-dictionary-reference.md`. **Not** the CPQ/Billing (`SBQQ`/`blng`) managed packages originally assumed. |
| Processing | Batch / Queueable Apex | `MembershipRenewalNotificationBatch`, `BillingEmailQueueable`, `CardDeclineDunningHandler`, `EftReconciliationBatch` — see `force-app/main/default/classes/` |
| Output | One extract file per run per channel | Same real column layouts adopted where confirmed (`NotificationGatewayService`'s `SMS_PUSH_COLUMNS`/`EMAIL_COLUMNS`/`CAU_EMAIL_COLUMNS`) |

## The shared destination pipe (unchanged by the migration)

| Stage | What happens | Status |
|---|---|---|
| AFT Stage 1 | A plaintext file lands in a local staging path (`%%PGPTemp.\MRD\...` on the mainframe-local `gid01943` server) | Confirmed, real job config observed |
| AFT Stage 2 | A predecessor-linked "Encrypted File Transfer Job" PGP-encrypts the staged file and relays it to MOVEit | Confirmed, real job config observed. MOVEit itself is confirmed capable of performing this encryption — Stage 2 may well be MOVEit's own automation, not a separate system. |
| MOVEit | Receives the encrypted file at `/users/SMSPUSH/OUTBOUND/` (per-channel path pattern inferred) | Confirmed as the relay point — not the final consumer |
| Final consumer | Very likely Salesforce Marketing Cloud | Strongly indicated (PGP key literally named `salesforce-prod-042325-1`, "sfmc xfer"; real SMS columns `SubscriberKey`/`Locale` are SFMC MobileConnect-specific), **not 100% confirmed** |

## What's genuinely still open

1. **How does Salesforce Apex hand a file to this pipe?** Apex can only make outbound HTTPS callouts — it cannot write to the Stage 1 staging file share directly. The leading candidate (per the MOVEit-can-self-encrypt confirmation) is a direct HTTPS upload to a MOVEit-exposed endpoint, but the specific endpoint, credential, and whether a new task needs provisioning are unresolved. Tracked as its own Jira story: *Confirm Apex-to-MOVEit Hand-off Endpoint*.
2. **Is the final consumer actually SFMC?** Strongly indicated, not confirmed — worth a direct conversation with whoever owns Marketing Cloud.
3. **No Billing/Payment object was found anywhere in the real org's data dictionary.** This doesn't block the source/destination picture above, but it does block two Apex classes (`MembershipRenewalNotificationBatch`'s amount-due/payment-in-transit gates, `CardDeclineDunningHandler`'s trigger source) — tracked separately as *Resolve Billing/Payment Data Source*.

See `docs/jira/revenue-cloud-migration-stories.csv` for how these are tracked as work items.
