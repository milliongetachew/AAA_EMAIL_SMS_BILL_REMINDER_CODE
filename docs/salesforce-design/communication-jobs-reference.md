# Communication / Jobs Reference (Real Operational Inventory)

Source: `Display Mbsp Communication Innovation Planning.xlsx`, supplied by
the user 2026-09-03 (three sheets: "Communication List", "Jobs & Programs",
"OPSDOC Job Info"). This is the team's own working inventory of every
outbound communication, its JCL/AFT job chain, and business-facing naming —
richer and more complete on the operational side than what the COBOL source
review alone could show. It **surfaces one real scope gap**: a program not
included in the original 10-file review.

## Scope gap: `MD065CC` is not in the reviewed source set

The "Communication List" sheet's first row is:

| Communication | Email | SMS | Push | Program |
|---|---|---|---|---|
| Annual CC Decline | X | X | X | **MD065CC** |

`MD065CC` does not appear anywhere in `attachments/` (the 10 files
documented in `docs/cobol-legacy/`). It sends all three channels (Email,
SMS, Push) for an "Annual CC Decline" communication — distinct from
`MD572EM`'s card-decline email and `md022cc`'s card-decline SMS/Push, both
already documented. **This program's source was never reviewed and its
behavior is unknown** — it should not be assumed similar to the other
decline-handling programs without reading its actual source. If the source
becomes available, it needs the same documentation pass as the other 10
programs before any Apex equivalent is designed for it.

## Scope gap: a planned future job, not yet built

A note on the "Jobs & Programs" sheet: *"Need to incorporate new job:
`MRD2023P` and `MRD2023O_AFT_EMAIL_SMS_FILE`. Added with `MEM-481189` and
`MEM-481267`."* This is planned/in-flight work referenced by ticket number,
not yet reflected in any reviewed source file — flagged as future scope,
not something to design against now.

## Open idea, not a decision: `MD300MA` → "LH screen"

Another note: *"Discussed option to insert call to `MD300MA` to write to LH
screen."* `MD300MA` is the correspondence-history logging routine already
covered in `docs/cobol-legacy/README.md`'s "cross-cutting theme" section
(the `Correspondence_Log__c` design in `high-level-design.md` is this
migration's equivalent). This note describes a **discussed, not decided**
extension — writing correspondence history to an "LH" screen (system not
identified from context) — worth surfacing to the business as a possible
requirement for `CorrespondenceLogger`, but not something to build against
without further clarification of what "LH" refers to.

## Real business-facing communication names

The "LH COMMUNICATION NAME (new)" column gives each technical program/job a
plain-language name — useful for `Renewal_Notification_Rule__mdt` records
and for talking to the business about this migration in terms they already
use, rather than program IDs:

| Program | Day offset | Business name |
|---|---|---|
| `MD021EX` | @-13 | Non Auto Pay Payment Due Notification @-13 |
| `MD022EX` | @-13 | Non Auto Pay Payment Due Notification @-13 |
| `MD022ER` | +45 days early | Non AutoPay SMS/PUSH Reminder Payment Due in 45 Days |
| `MD022ZA` | -77 (zero-auth) | *(unnamed in the sheet)* |
| `md022cc` | -12 / decline | Auto Pay SMS/PUSH Notification Payment Declined |
| `MD022LP` | +17 | Non AutoPay SMS/PUSH Reminder Payment Past Due 17 Days |
| `MD022LP` | +31 | Non AutoPay SMS/PUSH Reminder Payment Past Due 31 Days |
| `MD022LP` | +50 | Non AutoPay SMS/PUSH Reminder Payment Past Due 50 Days |
| `MD022EC` | +4, campaign-gated | Non AutoPay SMS Reminder Payment Past Due |
| `MD572EM` | card decline | Auto Pay Email Notification Payment Declined |
| `MD134ML` | MP bill-plan | *(unnamed in the sheet)* |

**Correction to prior understanding:** `MD022LP` is confirmed by this sheet
to be **one program reused for three separate day-offset variants** (+17,
+31, +50 days) via parameterization — not three different programs. This
matches what the COBOL documentation pass already found (`MD022LP` reads
its interval from `SYSIN`), and this sheet is independent confirmation of
that, not a contradiction.

## Real, complete AFT job inventory

The "Jobs & Programs" and "OPSDOC Job Info" sheets together give the full
job list — considerably richer than the handful of jobs visible in the
screenshots behind `moveit-aft-reference.md`. Every job follows the
`MRD<jobnum>O_AFT_<description>` naming pattern already documented there;
this is the complete list observed:

| AFT job (staging/output) | Output file pattern | Program | Predecessor JCL |
|---|---|---|---|
| `MRD1021O_AFT_Push_Notify` | `MRDPN.MD021.PUSH.NOTIFY*` | MD021EX | MRD1021P |
| `MRD1022O_AFT_SMS_FILE` | `MRDPN.MD022.SMS.EXTR*` | MD022EX | MRD1022P |
| `MRD1023O_AFT_45DAY_SMS_FILE` | `MRDPN.MD022.SMS.EARLY*` | MD022ER | MRD1022P |
| `MRD1024O_AFT_45DAY_PUSH_FILE` | `MRDPN.MD022.PUSH.EARLY*` | MD022ER | MRD1022P |
| `MRD1109O_AFT_SMS_MEM_ZEROAUTH` | `MRDPN.MD022.SMS.INT77*` | MD022ZA | MRD1022P |
| `MRD1104O_AFT_PUSH_MEM_ZEROAUTH` | `MRDPN.MD022.PUSH.INT77*` | MD022ZA | MRD1022P |
| `MRD1105O_AFT_SMS_MEM_PYMTDECLINED` | `MRDPN.MD022.SMS.INT12*` | md022cc | MRD1022P |
| `MRD1100O_AFT_PUSH_MEM_PYMTDECLINED` | `MRDPN.MD022.PUSH.INT12*` | md022cc | MRD1022P |
| `MRD1106O_AFT_SMS_MEM_NONAUTOPYMT_PLUS_17` | `MRDPN.MD022.SMS.INT17*` | MD022LP | MRD1022P |
| `MRD1101O_AFT_PUSH_MEM_NONAUTOPYMT_PLUS_17` | `MRDPN.MD022.PUSH.INT17*` | MD022LP | MRD1022P |
| `MRD1107O_AFT_SMS_MEM_NONAUTOPYMT_PLUS_31` | `MRDPN.MD022.SMS.INT31*` | MD022LP | MRD1022P |
| `MRD1102O_AFT_PUSH_MEM_NONAUTOPYMT_PLUS_31` | `MRDPN.MD022.PUSH.INT31*` | MD022LP | MRD1022P |
| `MRD1108O_AFT_SMS_MEM_NONAUTOPYMT_PLUS_50` | `MRDPN.MD022.SMS.INT50*` | MD022LP | MRD1022P |
| `MRD1103O_AFT_PUSH_MEM_NONAUTOPYMT_PLUS_50` | `MRDPN.MD022.PUSH.INT50*` | MD022LP | MRD1022P |
| `MRD1110O_AFT_SMS_MEM_NONAUTOPYMT_PLUS_04` | `MRDPN.MD022.SMS.INT04*` | MD022EC | MRD1022P |
| `MRD2510O_AFT_SMS_MEM_CAU` | `MRDPN.MRD2508P.OUTFILE.SMS*` | MD058CB | MRD2508P |
| `MRD2509O_AFT_PUSH_MEM_CAU` | `MRDPN.MRD2508P.OUTFILE.PSH*` | MD058CB | MRD2508P |
| `MRD2508O_AFT_EMAIL_MEM_CAU` | `MRDPN.MRD2508P.OUTFILE.EML*` | MD058CB | MRD2508P |
| `MRD1399O_AFT_MP_EMAILS` | `MRDPN.MD134.ALLCLUBS.MP.EMAILS*` | MD134ML | MRD1399P |
| `MRD1928O_AFT_Decline_Credit_Email_AL_CA_EC_HI` | `MRDPN.MD573.DCLIN.CARD.HEADER` + `MRDPN.DECLINE.CARD.EMAIL.{AL,CA,EC,HI}` | MD572EM | MRD1830P |
| `MRD1929O_AFT_Decline_Credit_Email_MO_NM_NN_TW_TX` | `MRDPN.DECLINE.CARD.EMAIL.{MO,NM,NN,TW,TX}` | MD572EM | `MRD1928O` (chained after the job above, not the JCL directly) |

**New finding: `MD572EM`'s output is split by state/region into per-state
files**, not one national file — 9 states observed across two AFT jobs
(`AL`, `CA`, `EC`, `HI`, `MO`, `NM`, `NN`, `TW`, `TX`), plus a separate
header file (`MRDPN.MD573.DCLIN.CARD.HEADER`). The `MD573` prefix on that
header file is worth noting — it may indicate a related header-writing
step/program (`MD573xx`) not captured in the reviewed source, or may simply
be a dataset-naming convention distinct from the program name `MD572EM`;
this is flagged, not resolved, and shouldn't be assumed either way without
checking the actual JCL/PROC for job `MRD1830P`.

## What this changes

- **`docs/cobol-legacy/README.md`** should note `MD065CC` as an identified
  but unreviewed 11th program (see edit there).
- **`moveit-aft-reference.md`**'s naming-convention section is confirmed
  accurate by this much larger real sample, and gains the full job list
  above instead of the handful visible in the original screenshots.
- **`docs/jira/revenue-cloud-migration-stories.csv`** gains a story to
  track reviewing `MD065CC` once its source is available, and the
  per-state splitting behavior belongs in `MD572EM`'s Apex-equivalent
  acceptance criteria (currently modeled as a single national email flow).
