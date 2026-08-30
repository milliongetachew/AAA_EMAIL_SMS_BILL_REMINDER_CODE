# MD058CB

Source: `attachments/M D 0 5 8 C B.txt`

## Summary

MD058CB processes a "CAU" (courtesy/card-auto-update) reject file
received from EFT: for each member whose credit card was declined and
who was sent through the auto-update process, it re-verifies the
member's current bill plan against the household table. Historically the
program's job was to flip the household bill plan back from `AC`
(autopay) to `AM` (manual) and queue a printed EIP letter when a card
could not be auto-updated, or to report an "out-of-sync" / "out-of-
territory" condition otherwise. As of a 2025 change (MEM-480905) the
bill-plan-flip behavior was disabled and the program's primary output
became three new digital notification files — SMS, Push, and Email — sent
directly to the affected member, each logged to a correspondence-history
table.

This is the largest and most structurally complex program in this set:
it has mainframe checkpoint/restart logic, a `GO TO`-based deadlock retry
path, and two parallel "old" vs. "new" letter-processing code paths
selected per club/bill-plan.

## Inputs and Outputs

- **Input file** `CAUCCREJ-FILE` (DD `CAUCCREJ`, PIC X(112), copybook
  `EFT270C` / `WS-MRDCCREJ-REC`): one record per card-auto-update reject,
  including club code (`E270-CLUB-CODE`/`E270-PRODUCT-PREFIX`),
  membership number (`E270-PRODUCT-ID`), old card type/last-4/expiration.
- **Output files** (all added by MEM-480905):
  - `MD058CB-OUTPUT-SMS` (DD `OUTSMS`, PIC X(111), copybook `MRD058SF`)
  - `MD058CB-OUTPUT-PUSH` (DD `OUTPSH`, PIC X(133), copybook `MRD058PF`)
  - `MD058CB-OUTPUT-EMAIL` (DD `OUTEML`, PIC X(133), copybook `MRD058EF`)
  Each has a header record (written once, on the first row) plus one
  detail record per notified member.
- **DB2 tables**: `MBRSHP_HOUSEHOLD` (DCLGEN `MBRHSHLD`), `AAA_CLUBS_TB`
  (company/GL info), `EMS_WORK_CAU` (DCLGEN `EMSWKCAU` — legacy/"old
  path" letter queue), `EMS_WORK_LETTER` (DCLGEN `EMSWKLTR` — "new path"
  letter queue), `CUST_PHONE` (DCLGEN `MACSCUPS`), `CUST_EMAIL` (DCLGEN
  `MACSCUES`), plus `MBRSHP_NEXT_EVENT` (queried inline for next-event
  bill plan).
- **External subprograms**: `MD920BR` (job name), `MD930BR` (processing
  date), `MD380MA` (household read/update — expiration date, region,
  billing customer id, and historically bill-plan update), `MD699BR`
  (club abbreviation and club billing-rules group, called twice for two
  different purposes), `MD607BR` (determines old-vs-new letter
  processing path), `MD60BBR` (triggers monthly-plan letter `168` via
  its own CSR), `MD610BR` (amount due), `MD614BR` (next-event update —
  now unused, see below), `MD630BR` (member summary write — now unused,
  see below), `MC501BCD` (lodge type), `MC502BCD` (name/address),
  `MD999CK` (declared, not called in the visible source), `UT020DT`
  (MEM-481325: computes day-count between two dates), `MD300MA`
  (MEM-481283: correspondence-history update), plus restart/checkpoint
  copybook logic (`MRD910CA`–`MRD910CD`) that itself calls a restart
  program.
- **Copybooks**: `EFT270C`, `MRD058C` (old sync/territory output
  record), `MRD058SF`/`MRD058PF`/`MRD058EF` (new SMS/Push/Email output
  records), `UTL020C` (UT020DT linkage), `MRDR04C` (club abbreviation),
  `MRDR48C2` (club billing-rules group), `MRD250C` (old EIP letter
  format), `MRD300C` (correspondence history), `MRD380C`, `MRD607C`,
  `MRD60BC`, `MRD610C`, `MRD614C`, `MRD630C`, `MRD900C`, `MRD901C`,
  `MRD903C`, `MRD910C`, `MRD960C`, `MAC501C`, `MAC502C`.

## Key Data Structures

- `WS-MRDCCREJ-REC` (copybook `EFT270C`): the input CCREJ record — club,
  member, old card type/last-4/expiration date.
- `WS-OUTREC` (copybook `MRD058C`): the legacy "out of sync" / "out of
  territory" report record (name, bill plan, state, zip, card last-4,
  address, city, expiration date).
- `WS-SMS-OUT` / `WS-PUSH-OUT` / `WS-EMAIL-OUT` (copybooks `MRD058SF`/
  `MRD058PF`/`MRD058EF`): the three new notification record layouts —
  each carries customer id/subscriber key, club code, first name, zip,
  membership number, expiration date, card last-4, locale (`en-US`), and
  a header/detail distinction.
- `MD48-INPUT-OUTPUT-RECORD` (copybook `MRDR48C2`): per-club table of
  which bill-plan codes require "monthly due" calculation
  (`MD48-BP-BILL-PLAN`/`MD48-BP-CALC-MONTHLY-DUE-I`, `OCCURS`), used to
  branch between the old and new (`2500`) processing paths.
- `MD607-INPUT-OUTPUT` (copybook `MRD607C`): output of the "which letter
  path" business-rule lookup — `MD607-PROCESS-OLD` routes to
  `EMS_WORK_CAU`; otherwise (and only if printing isn't suppressed —
  see `DO-PRINT` below) rows go to `EMS_WORK_LETTER`.
  `MD607-CYC-START-OFFSET-DY`, `MD607-MBR-CANCL-OFFSET-DY`,
  `MD607-PRINT-CARDS-I`, `MD607-NXT-EVT-LOOKBACK-I`, `MD607-MRD-TEXT`,
  `MD607-BILL-CORR-TYPE-C` feed the `EMS_WORK_LETTER` insert.
  `WS-SKIP-PRINT-FLAG` (level-88 `DO-NOT-PRINT`/`DO-PRINT`, MEM-481325):
  set based on `UT020DT`'s day-count between the member's current-term
  expiration and the processing date — if 23 days or fewer remain, the
  printed CAU letter is suppressed.
- `WS-RESTART-SAVE-DATA`: checkpoint/restart counters (input count,
  out-of-sync count, out-of-territory count, bill-plan-change count,
  output counts, skipped count, etc.) persisted/restored via the
  `MRD910C*` restart copybooks so a failed run can resume mid-file.
- `WS-MACS-LODGE-TYPE` (level-88 `OUTOF-TERRITORY` for codes `'1'`,
  `'3'`, `'4'`, `'6'`): lodge classification from `MC501BCD`, used to
  route AC-billplan members to either the standard CAU letter path or
  the "out of territory" file.

## Control Flow

1. **0000-MAINLINE**: `1000-INITIALIZE-ROUTINE`, get a DB2 timestamp,
   then loop `1500-PROCESS-FILE` until end of input, then
   `2050-EOF-ROUTINE`.
2. **1000-INITIALIZE-ROUTINE**: gets the job name (`MD920BR`), opens the
   input file and the three new output files (aborting on any bad file
   status), gets the processing date (`MD930BR`), initializes restart
   state (`9900-RESTART-INIT`), and reads (or repositions past
   already-processed rows, per the restart checkpoint) the first input
   record. An empty input file is treated as a normal (non-error) early
   exit.
3. **1500-PROCESS-FILE** (per CCREJ input record):
   a. **1600-CALL-MD380MA**: reads household info (region, billing
      customer-system-id) for the record's club/member.
   b. **1700-GET-EIP-LETTER-GRP-RULES**: calls `MD699BR` for the club's
      billing-rules group (`MD48-*` table of bill-plan → monthly-due
      flags).
   c. **1800-IF-MONTHLY-PLAN**: scans that table to see whether the
      household's bill-plan type requires monthly-due calculation.
   d. If monthly-plan: **2500-PROCESS-FILE** calls `MD60BBR` to trigger
      letter `168` via its own callable service (no direct DB write
      here).
      Else: **2000-PROCESS-FILE-OLD**, the traditional path:
      - On a club change, looks up the club abbreviation
        (`8000-GET-CLUB-NAME-ABBREV`) and determines the letter
        processing path (`8100-DETERMINE-LETTER-PATH`, via `MD607BR`).
      - **8200-CHECK-BILLPLAN-AC**: re-selects the current
        `MBRSHP_HOUSEHOLD` row (bill plan, expiration, lodge code,
        region/segment); if not found in the expected window, the
        record is skipped.
      - **8250-CHECK-NBR-DAYS-EXPIRE** (MEM-481325): computes days to
        expiration via `UT020DT`; sets `DO-NOT-PRINT` if ≤ 23 days
        remain.
      - **8300-GET-NAME-ADDR** (`MC502BCD`) and **8400-GET-AMOUNT-DUE**
        (`MD610BR`).
      - If the household's bill plan is no longer `AC`, writes an
        "out-of-sync" row (**2100-WRITE-SYNC-FILE**, job code
        `MD58SYNC`, inserted into `EMS_WORK_CAU` purely as a reporting
        record).
      - Otherwise (still `AC`): checks the next-event bill plan
        (**8500-CHECK-BILLPLN-NXTEVT**) and lodge type
        (**8600-GET-LODGE-TYPE**, via `MC501BCD`):
        - Next-event still `AC` and **not** out-of-territory →
          **2200-WRITE-CAU-LTR-N-UPDATE**: writes to `EMS_WORK_CAU` (old
          path) or, if the new path applies **and** `DO-PRINT` is set,
          to `EMS_WORK_LETTER` (**6200-WRITE-EMS-WORK-LETTER**). *Note:*
          the household bill-plan-to-`AM` flip
          (**2210-CHANGE-HOUSEHOLD-AM**), next-event update
          (**2220-UPDATE-NEXT-EVENT**), and member-summary write
          (**2230-WRITE-MEMBER-SUMMARY**) paragraphs still exist in
          source but their calls from `2200` are **commented out**
          under MEM-480905 — they are dead code as of that change.
        - Next-event still `AC` and out-of-territory →
          **2300-WRITE-TERR-FILE** (job code `MD58TERR`, also into
          `EMS_WORK_CAU`, but flagged/report as a distinct "out of
          territory" bucket).
   e. **1900-CREATE-OUTPUT-FILES** (MEM-480905, runs for **every** input
      record regardless of the old/new path outcome above):
      - Gets name/address if not already fetched.
      - **1910/1920**: looks up a valid cell phone (`CUST_PHONE`, role
        `CL`, not expired) via **8700-GET-CELL-NUMBER**; if found,
        writes a Push detail record.
      - **1930/1940**: if the same phone lookup found a number, writes
        an SMS detail record (MEM-481270 tightened this to require a
        found phone before building the SMS record).
      - **1950/1960**: looks up a valid, non-expired email
        (`CUST_EMAIL`) via **8800-GET-EMAIL-ADDRESS**; if found, writes
        an Email detail record.
      - Each of the three writes is preceded by a call to
        **1970-UPDATE-CORR-HIST** (MEM-481283) with a distinct
        correspondence-type code (`'868'` push, `'768'` SMS, `'668'`
        email), which calls `MD300MA` to log the send; "member
        cancelled" / "member missing" responses are tolerated
        (displayed, not fatal).
   f. **9901-CHK-COMMIT-FREQ** (checkpoint), then reads the next input
      record.
4. **2050-EOF-ROUTINE**: closes all four files, finalizes the restart
   checkpoint (**9902-RESTART-END**), and displays extensive summary
   counts — input, out-of-sync, out-of-territory, bill-plan-change count
   (effectively always zero now that the flip is disabled), skipped,
   old-path output, new-path letter output, letter-168 count, and the
   three new push/SMS/email counts.
5. **9000-ERROR-HANDLING**: on a DB2 deadlock/timeout SQLCODE, retries up
   to `MD910-RETRY-N` times by rolling back, closing the input file, and
   issuing `GO TO 0000-MAINLINE` — an unstructured restart of the entire
   program from the top, relying on the checkpoint/restart mechanism
   (`MRD910C*`) to reposition correctly. Any other error rolls back and
   abends.

## Modification History

| Date | Who | Description |
|---|---|---|
| 04/01/14 | WVH | SR1014908 — changing from monthly to semi-monthly |
| 04/18/14 | CS0307 | SR1014857 — lodges 94/95/96/99 combined into lodge 99; call `MC501BCD` to get lodge type to distinguish old vs. new lodge definitions |
| 06/12/14 | CS0182 | IM4256690 — correct inputs to `MC501BCD` (club/product number were swapped) |
| 07/15/14 | SF | MEM-13-06 — recompile for copybook change |
| 12/16/14 | SIF | SR1015249 — set up to divert letters to the new `EMS_WORK_LETTER` process |
| 02/05/15 | PEB | INT-14-02 — recompile for `EMSWKLTR`/`MRD607C` change |
| 02/10/15 | CT | INT-14-02 — added new fields to `EMS_WORK_LETTER` (card-issue reason, letter role, spinoff roles) |
| 02/27/17 | MD | MEM-16-06 — added letter `168` for MP bill plan |
| 08/14/25 | MD | MEM-481270/MEM-480905 (SMS/Push/Email output) — updated SMS check for zero telephone numbers, trimmed trailing spaces from output, added country code |
| 01/15/26 | PM | MEM-481325 — CAU print-letter suppression for members −23 to −17 days from expiration |
| 10/14/25 | FA | MEM-481283 — Membership Communication Visibility: update the correspondence table for all email, SMS, and push correspondence |

Note: the source lists these last three entries out of strict date order
(08/14/25, then 01/15/26, then 10/14/25) — transcribed as written in the
header rather than re-sorted, since the actual commit/deploy order isn't
verifiable from this source.

## Ambiguous / Environment-Dependent Notes

- **Checkpoint/restart facility**: paragraphs `9900-RESTART-INIT`,
  `9901-CHK-COMMIT-FREQ`, `9902-RESTART-END`, `9910-CALL-RESTART-PGM`
  are `COPY`-generated from `MRD910CA`–`MRD910CD`, which are not part of
  this file set. The exact restart/reposition semantics (how
  `1200-READ-OR-REPOSITION` skips already-processed rows after a
  restart) cannot be fully traced without those copybooks.
- **`GO TO 0000-MAINLINE`** inside `9000-ERROR-HANDLING` is unstructured
  control flow that restarts the whole program in place on a DB2
  deadlock, relying entirely on the checkpoint mechanism above to avoid
  reprocessing; flagged explicitly as something that does not map to a
  literal Apex equivalent (see translation guidance: batch retry /
  transaction-savepoint patterns would replace this).
- **Dead code**: `2210-CHANGE-HOUSEHOLD-AM`, `2220-UPDATE-NEXT-EVENT`,
  and `2230-WRITE-MEMBER-SUMMARY` (the historical "flip bill plan back
  to AM" behavior) remain fully coded but are no longer called as of
  MEM-480905 — worth confirming with the business whether this is
  permanent before treating it as removed functionality in any
  reimplementation.
- Hard-coded correspondence/letter codes (`WS-CAU-LETTER = '068'`,
  `WS-LETTER-168-C = '168'`, correspondence types `'868'/'768'/'668'`)
  are meaningful only in the context of the external `MD607BR`/`MD48`
  business-rule tables and the correspondence-type registry — their full
  definitions are outside this source.
- Input file (`CAUCCREJ`) is stated to originate from EFT (the auto-pay
  processing/clearing system) but that upstream job is not part of this
  review.
