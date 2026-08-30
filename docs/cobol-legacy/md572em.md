# MD572EM

Source: `attachments/MD572EM.txt`

## Summary

MD572EM generates the "credit card decline" notification email extract.
It drains a DB2 work table (`EMS_WORK_CCREJ`, populated upstream by
Finance when a member's autopay credit card is declined) club by club,
validates and enriches each row (bill plan, amount still due, expiration
date, years of service, customer email), and writes one semicolon-
delimited output row per member who should receive a decline email —
deleting each row from the work table as it is processed (or skipped) so
it is not picked up again. It also produces a per-club and grand-total
summary report of how many declines were processed, emailed, skipped,
paid, or cancelled.

## Inputs and Outputs

- **Input file** `CLUB-FILE-IN` (DD `MD572I`, PIC X(80)): a list of club
  codes to process this run; used to build an in-memory table
  (`IDX-CLUB-DATA`, up to 15 clubs) of club code + name + running
  counters, driving both the eligible-club whitelist check and the final
  report.
- **Output files**: `EMAIL-FILE-OUT` (DD `MD572O1`, PIC X(240),
  semicolon-delimited detail records, copybook `MRD572C`) and
  `REPORT-FILE-OUT` (DD `MD572O2`, PIC X(100), comma-delimited
  per-club/total summary report).
- **DB2**: `SQLCA`, `EMS_WORK_CCREJ` (DCLGEN `EMSWKCCR`) — the work table
  driving this run — and `MBRSHP_NEXT_EVENT` (DCLGEN `MBRNXEVT`).
- **Cursor `CURSOR-WORKTABLE`**: `SELECT CLUB_C, MBR_N, EMAIL_TEXT FROM
  EMS_WORK_CCREJ WHERE PROCESS_D <= :WS-PROCESS-DT AND BILL_PLAN_C <
  'MP' ORDER BY CLUB_C` — the `EMAIL_TEXT` column contains a
  pre-packed member/card-decline record (moved into copybook `CRD206C`)
  rather than individual columns.
- **External subprograms**: `MD930BR` (processing date), `MD699BR` (club
  name lookup), `MD610BR` (amount currently due), `MD380MA` (household
  info — current term expiration date), `MD642BR` (member info — AAA
  join year), `MC501BCD` (customer data/email), `MD999CK` (16-digit
  membership number).
- **Copybooks**: `CRD206C` (input/decline record, `MD572-INPUT`),
  `MRD572C` (output record, `MD572-OUTPUT`), `MRD380C` (MD380MA
  linkage), `MRD4421C` (MD642BR linkage), `MAC501C`, `MRDR03C` (MD699BR
  linkage), `MRD610C`, `MRD999CK`, `MRD930C`, `MRD960C`, `MRD900C`,
  `MRD901C`.

## Key Data Structures

- `IDX-CLUB-DATA` (`OCCURS 15 INDEXED BY IDX-C`): per-club working table
  — code, name, and six counters (decline, email, no-email, skip, paid,
  cancel) — built from `CLUB-FILE-IN` at startup and searched
  (`SEARCH ... VARYING IDX-C`) for every fetched work-table row; a row
  whose club isn't in this table causes an abend ("invalid club input").
- `MD572-INPUT` (copybook `CRD206C`): the decline record embedded in
  `EMS_WORK_CCREJ.EMAIL_TEXT` — club code, member id, card type code,
  transaction amount, last-4 digits, card expiration date.
- `MD572-OUTPUT` (copybook `MRD572C`): the 15-field semicolon-delimited
  output — extract date, club, 16-digit membership number, expiration
  date, total due, customer number, name suffix/first/last, email +
  email-valid code, long card type (`VISA`/`MASTERCARD`/`AMEX`/
  `DISCOVER`/`UNKNOWN`), card last-4, card expiration, years of service.
- `WS-AMOUNT-DUE` (`PIC 9(04)V99`): current total due from `MD610BR`;
  zero means the member already paid during the window between the
  decline and now.
- `WS-YEAR-SERV-9` = expiration year − AAA join year (min 1).

## Control Flow

1. **A0000-INITIALIZE**: gets the current DB2 date/time, opens the three
   files, gets the batch processing date (`MD930BR`), opens
   `CURSOR-WORKTABLE`, reads `CLUB-FILE-IN` into `IDX-CLUB-DATA`
   (**A4000-GET-ALL-CLUBS**, calling `MD699BR` per club for its display
   name — **A5000-GET-CLUB-NAME**; overflow beyond 15 clubs aborts the
   run), writes the report header row, and fetches the first work-table
   row.
2. **B0000-PROCESS-MEMBER-RECS** loops until the cursor is exhausted
   (`MD572I1-EOF`), for each row running a chain of gated steps (each
   step only runs `IF CONTINUE-PROCESS`, i.e. no earlier step set
   `BYPASS-RECORD`):
   - **B2000-CHECK-CARD-TYPE**: maps the raw card-type code to a display
     string.
   - **B2500-CHECK-BILL-PLAN**: selects the member's current bill plan
     from `MBRSHP_NEXT_EVENT`; if not found (SQLCODE 100) the membership
     is assumed cancelled — the work-table row is deleted, counted as
     cancelled, and the record bypassed.
   - **B3000-GET-TOTAL-DUE**: calls `MD610BR`. If the amount due is now
     zero, the member has already paid — the work-table row is deleted,
     counted as paid, and bypassed. Else if the bill plan is still
     `'AC'` (autopay) and still unpaid, the row is left on the work
     table (to be retried the next run) and bypassed, counted as
     skipped.
   - **B4000-GET-EXPDT-YRSERV**: gets the current term expiration
     (`MD380MA`) and AAA join year (`MD642BR`) and computes years of
     service.
   - **B5000-GET-16DIG-MBRSHP**: calls `MD999CK`.
   - **B1000-GET-CUSTOMER**: calls `MC501BCD`; if the customer isn't
     found, aborts. If found but has no usable email (must be non-blank
     and validity code `'1'` or `'3'`), the row is deleted, counted as
     no-email, and bypassed.
   - **B6000-WRITE-EMAIL-REC**: builds the output record; as a data-
     integrity guard (INC574770), if any semicolon characters remain
     inside the populated fields (via `INSPECT ... TALLYING`), the row
     is **not written** (counted as no-email instead) to avoid producing
     a malformed delimited row; otherwise the row is written and counted
     as emailed.
   - **B7000-DELETE-CCREJ-ROW**: deletes the row from `EMS_WORK_CCREJ`
     and commits (**B8000-COMMIT**) — performed for every row that
     reaches this point (whether emailed or bypassed earlier via one of
     the explicit delete calls above).
   - Fetches the next row (**R0000-FETCH-MEMBER**), which also validates
     the fetched club exists in `IDX-CLUB-DATA` (see above).
3. **Z0000-WRAP-UP**: for each club in `IDX-CLUB-DATA`, computes the net
   decline count (`decline − skip − paid − cancel`) and writes a report
   row with the email percentage (**Z1000-WRITE-REPORT**); then writes a
   grand-total row (**Z2000-WRITE-REPORT-TOTAL**); closes all files.

## Modification History

| Date | Who | Description |
|---|---|---|
| 02/27/14 | C Arrastia | SR1011408 — decline card email, initial install |
| 02/27/17 | Phil Beard | MEM-16-06 — limit to AC bill plan; MP gets a new program |
| 03/28/17 | Minh Diep | INC574770 — remove email rows whose fields still contain a semicolon (would corrupt the delimited format) |
| 03/23/17 | Phil Beard | MNT-16-06 — only exclude MP bill plan (loosened from AC-only) |
| 07/24/17 | SFavrin | INC572157 — fix next-event `SELECT` to return only one row |
| 10/11/17 | MQ | INC767771 — validate the member before attempting to get the customer email (moved the `MC501BCD` call after member validation) |

## Ambiguous / Environment-Dependent Notes

- The header comment "IMPORTANT: INPUT FILE MUST BE SORTED BY CLUB"
  most plausibly refers to the `CURSOR-WORKTABLE` `ORDER BY CLUB_C`
  clause (DB2 guarantees this) rather than `CLUB-FILE-IN`, whose order
  doesn't matter to the `SEARCH`-based lookup — but the comment's exact
  intent isn't fully resolvable from source alone.
- `CLUB-FILE-IN` is capped at 15 entries (`IDX-C-MAX`); if the business
  ever operates more than 15 clubs simultaneously this program aborts
  with a table-overflow error — a hard-coded scale limit worth flagging
  for any reimplementation.
- The cursor predicate `BILL_PLAN_C < 'MP'` is a string/alphabetic
  comparison used to exclude monthly-pay ("MP" and anything sorting at
  or after it) bill-plan codes; the full domain of bill-plan-code values
  and whether this comparison reliably excludes exactly the intended set
  is not verifiable from this source alone.
- Upstream population of `EMS_WORK_CCREJ` (by Finance, per the header
  comment) is outside this program.
