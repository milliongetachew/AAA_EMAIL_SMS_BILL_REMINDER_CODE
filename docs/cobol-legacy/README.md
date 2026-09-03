# Legacy COBOL Program Documentation — Membership Renewal / Billing Notification Batch Pipeline

This directory documents 10 IBM Enterprise COBOL batch programs
(mainframe, DB2, CICS-adjacent callable subroutines) that were exported
from production for reference/archival purposes. Each program has its
own documentation file; this README summarizes the whole set and how the
programs relate to each other.

Source files live in `../../attachments/` (not modified by this
documentation pass). Some original filenames have a space between every
character (an artifact of how they were exported/attached) — the actual
`PROGRAM-ID` inside each file is unaffected and is what was used to name
these docs.

## System Overview

Collectively these programs form a **membership renewal and billing
notification batch pipeline** for a membership organization (club/AAA-
style structure with clubs, households, and per-member billing plans).
The pipeline's job is to identify members in various renewal, payment-due,
or payment-problem states and generate outbound notification extracts —
SMS text messages, mobile push notifications, and/or emails — that are
picked up by downstream systems (an SMS gateway, a mobile push service,
and "EBIZ"/EIP email processing) and actually delivered to members.
Every program in this set is a nightly/scheduled batch job (`PROCEDURE
DIVISION` + `GOBACK`, no online/CICS transactions), most driven by a DB2
cursor over membership tables (`MBRSHP_HOUSEHOLD`, `MBR_PRD_DTL`,
`MBRSHP_NEXT_EVENT`, `MBR_INFO`) or by a file/table prepared by an
upstream extract step.

Common building blocks shared across nearly all of these programs:

- **`MD930BR`** — returns the batch processing date.
- **`MC501BCD`** — MACS customer-data service: name, email + validity
  code, phone numbers (with role/validity/expiration), zip, lodge type.
- **`MC556BR`** — SMS/text-message consent (opt-in) authorization check.
- **`MD999CK`** — converts a club + short membership number into the
  16-digit "check-digit" membership number used on outbound
  communications.
- **`FN435BT`** — "payment in transit" (PIT) check, used to avoid
  reminding someone whose payment is already being processed.
- **`MD610BR`** — computes the member's current total amount due.
- **`MD699BR`** — club-level business-rules lookup (used for things like
  "how many days before/after renewal should this reminder go out",
  club name/abbreviation, and billing-plan grouping rules).
- **`MRD900C`/`MRD901C`/`MRD902C`/`MRD903C`** — the shared error-handling,
  abend, and SQL-error-code copybook family used by every program for
  consistent diagnostics and abend behavior.

## Programs

| Program | One-line description | Doc |
|---|---|---|
| **MD021EX** | CSV extract of members in renewal, unpaid, no payment-in-transit, due in a fixed 13 days — the original "mobile notification subscriber" file. | [md021ex.md](md021ex.md) |
| **MD022EX** | Clone of MD021EX using business-rule-driven day offsets, consent check, and amount-due gating; writes a single semicolon-delimited SMS extract. | [md022ex.md](md022ex.md) |
| **MD022ER** | Clone of MD022EX that splits output into separate SMS and Push files, with SMS still gated on consent but Push written independent of consent. | [md022er.md](md022er.md) |
| **MD022EC** | Campaign-code-gated SMS reminder for members past their renewal due date (+3, later +5 days), scoped to a growing whitelist of marketing campaign codes and clubs. | [md022ec.md](md022ec.md) |
| **MD022LP** ("late pay") | General (non campaign-restricted) SMS + Push reminder for members in specific late-payment billing events at their renewal date. | [md022lp.md](md022lp.md) |
| **md022cc** ("credit card decline") | SMS + Push notification for members whose next billing event is a credit-card decline; as of May 2025 sends SMS with **no consent check** (consent gate was explicitly removed). | [md022cc.md](md022cc.md) |
| **MD022ZA** | "Pre-auth $0.00" SMS + Push file for members ~77 days before expiration; reads a pre-filtered upstream extract file rather than querying DB2 directly (clone of a `MD145A` program not in this set). | [md022za.md](md022za.md) |
| **MD134ML** | Generates monthly-pay ("MP") bill-plan correspondence emails from an EIP extract file, with a special suppression rule for letter 139 when a member made the change themselves on the web. | [md134ml.md](md134ml.md) |
| **MD572EM** | Generates "credit card decline" emails by draining a Finance-populated DB2 work table (`EMS_WORK_CCREJ`), with per-club and total summary reporting. | [md572em.md](md572em.md) |
| **MD058CB** | Processes EFT's card-auto-update (CAU) reject file: legacy bill-plan-sync/letter-queue logic (largely superseded/disabled) plus, as of 2025, direct SMS/Push/Email notification generation with correspondence-history logging. | [md058cb.md](md058cb.md) |

## Relationships Between the Programs

### The `MD022*` family

`MD021EX` is the original program in this lineage: a simple CSV extract
of members due for a renewal payment in exactly 13 days, filtered by
payment-in-transit status, with no consent or amount-due logic yet.

`MD022EX` was explicitly cloned from `MD021EX` (per its own header
comment) to add: a business-rule-driven day offset (via `MD699BR`
instead of a hard-coded `13`), an SMS-consent check (`MC556BR`), and an
amount-due gate (`MD610BR`) — turning it from a generic subscriber list
into an actual SMS-eligibility extract with amount-due data.

`MD022ER` was then cloned from `MD022EX` to split the single output file
into separate SMS and Push files, changing the Push channel to not
require SMS consent.

`MD022EC`, `MD022LP`, and `md022cc` are a closely related sub-family that
share the same output record copybook family (`MD022SP`/`MRD022EC`) and,
in the case of `MD022EC`/`MD022LP`/`md022cc`, the identical
`(processing date − SYSIN interval) + 1 YEAR` target-date formula:

- **`MD022EC`** is the most restrictive: only members past renewal by a
  configurable interval **and** enrolled in specific marketing campaign
  codes (a whitelist that has been extended repeatedly, club by club,
  over 2024–2025).
- **`MD022LP`** ("late pay") applies the same billing-event filter as
  `MD022EC` but with no campaign-code/club restriction — the general-
  purpose version.
- **`md022cc`** targets a different population entirely (members with a
  credit-card-decline billing event) and, notably, had its consent check
  removed in May 2025 (MEM-482325) — it is the only program in this set
  that sends SMS without an opt-in check.

**`MD022ZA`** is architecturally different from the rest of the family:
it does not run its own DB2 cursor over membership tables at all — it
consumes a pre-filtered "-77 day" extract file produced by an upstream
job (explicitly documented as a clone of a `MD145A` program, which is
not part of this file set) and only adds contact-info enrichment before
writing SMS/Push output.

### Email-focused programs

**`MD134ML`** and **`MD572EM`** are the email-generation counterparts to
the SMS/Push family above, each driven by its own upstream extract/work
table rather than a live membership-table cursor:

- `MD134ML` consumes a general "EIP" correspondence-candidate file and
  produces monthly-pay-plan emails, delegating the actual
  send/no-send/letter-type decision to the `MD607BR` business-rules
  service.
- `MD572EM` drains a Finance-populated work table of credit-card
  declines and produces decline-notice emails, with its own club-scoped
  summary reporting.

### `MD058CB` — the CAU/EFT reconciliation program

**`MD058CB`** is the largest and most structurally distinct program: it
reconciles EFT's card-auto-update reject file against the current
household billing state, historically to flip a member's bill plan from
autopay (`AC`) back to manual (`AM`) and queue a printed letter when a
card couldn't be updated. That bill-plan-flip behavior has since been
disabled (2025, MEM-480905) in favor of directly generating SMS, Push,
and Email notification files for the affected member — making it, in its
current form, a fourth (SMS/Push/Email-producing) sibling of the
`MD022*`/`MD572EM`/`MD134ML` programs, layered on top of its older
letter-queue/bill-plan-sync logic which remains present but partially
dormant. It is also the only program in this set with mainframe
checkpoint/restart logic and a `GO TO`-based deadlock-retry loop.

### Shared, cross-cutting theme: correspondence-history visibility

Several 2025 changes across these programs (MEM-481279 in `MD134ML`,
MEM-481283 in `MD058CB`) add calls to `MD300MA` to log every outbound
correspondence (email/SMS/push) into a member correspondence-history
table — a cross-program initiative ("Membership Communication
Visibility") to centralize a record of what was sent to whom, layered on
top of each program's pre-existing extract-generation logic.

## Notes on Scope

This documentation set is descriptive only — no Apex/Salesforce
translation is included here. Several programs reference external
copybooks and called subprograms (e.g. `MD699BR`'s underlying business
rule tables, the `MRD910C*` restart copybooks used by `MD058CB`,
`MD145A` referenced by `MD022ZA`) that were not part of the reviewed file
set; where a program's behavior depends on one of those, it is called
out explicitly in that program's "Ambiguous / Environment-Dependent
Notes" section rather than guessed at.

**Known gap — an 11th program, not reviewed:** the team's own
communication inventory (`docs/salesforce-design/communication-jobs-reference.md`,
sourced from `Display Mbsp Communication Innovation Planning.xlsx`)
identifies **`MD065CC`** ("Annual CC Decline" — Email + SMS + Push) as a
real production program. Its source was not part of `attachments/` and was
never reviewed here — its behavior is unknown and should not be assumed
similar to `MD572EM` or `md022cc` (the other decline-handling programs)
without reading its actual source.
