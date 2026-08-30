# MD022EX

Source: `attachments/M D 0 2 2 E X.txt`

## Summary

MD022EX is a clone of `MD021EX` (see header comment) that produces a
semicolon-delimited extract of members in renewal, not on autopay, with
an unpaid membership payment due, no payment-in-transit, who have opted
in to text messaging (SMS consent). Unlike `MD021EX`, the number of days
before/after the due date is driven by a business-rules subroutine
(`MD699BR`) rather than a hard-coded constant, and the extract also
carries the amount currently due. This file is consumed by the SMS
notification pipeline (single output file, message type fixed to `SMS`).

## Inputs and Outputs

- **Input file** `DATE-FILE` (DD `PROCDTIN`): supplies the batch
  processing date.
- **Output file** `OUT-FILE` (DD `MD022OP`, `OUTREC` PIC X(300)):
  semicolon-delimited CSV with header row `WS-HEADER` (ExtractDate;
  MessageType; CustID; EmailAddress; SubcriberKey; ClubCode; FirstName;
  LastName; ExpirationDate; AmountDue; MembershipNumber; Locale;
  MobileNumber;).
- **DB2 tables**: `MBRSHP_HOUSEHOLD`, `MBR_PRD_DTL`, `MBR_INFO`/`MEMBER`,
  `SQLCA` (DCLGEN includes `MBRHSHLD`, `MBRPRDDT`, `MEMBER`).
- **Cursor `CUSTID`**: same shape of join as `MD021EX` (household +
  product detail + member info, `CUR_TERM_EXP_D < REN_TERM_EXP_D`,
  `FK_BILL_PLAN_TYP_C = 'AM'`, unpaid, effective on `EFF_D =
  :WS-TARGET-DATE`), with `CUR_TERM_EXP_D` also fetched for display on
  the extract.
- **External subprograms**: `FN435BT` (PIT check), `MC501BCD` (customer
  data + phone), `MD999CK` (16-digit membership number), `MD610BR`
  (amount due), `MD699BR` (business rules — number of SMS days),
  `MC556BR` (SMS consent/authorization check).
- **Copybooks**: `MAC501C`, `MAC556C`, `MAC900C` (MC556 error area),
  `MRD610C` (MD610BR linkage), `MRD960C` (MD610BR companion), `MRDR23C`
  (MD699BR business-rules linkage), `MRD022C` (output record layout),
  `MRD900C`/`MRD901C`/`MRD903C`, `MRD999CK`, `UTL000C`, `FIN435C`.

## Key Data Structures

- `MD23-INPUT-OUTPUT-RECORD` (copybook `MRDR23C`): linkage to `MD699BR`;
  input club code (hard-coded `'001'`/Alabama — see note below), region,
  processing date; output `MD23-REN-DUE-SMS-PUSH-DAYS`, the configured
  number of days used to compute the target date.
- `WS-SMS-DAYS` (`COMP PIC S9(04)`): number of days (from business rules)
  added to the processing date to compute `WS-TARGET-DATE`.
- `MD610-LINK-DATA` / `MD960-LINK-DATA` (copybooks `MRD610C`/`MRD960C`):
  linkage to the amount-due subroutine; `MD610-TOTAL-DUE` is the dues
  amount used to populate the extract and to gate whether a row is
  written at all.
- `MC556-INPUT-OUTPUT` / `MC900-ERROR-DATA`: linkage to the SMS-consent
  authorization lookup; `MC556-O-AUTHORIZED-FLAG = 'Y'` sets
  `MEMBER-CONSENT-YES`.
- `WS-OUTREC` (copybook `MRD022C`): the 13-field semicolon-delimited
  output record — extract date, message type (`SMS`), customer id,
  email, subscriber key, club code, first/last name, expiration date,
  amount due, 16-digit membership number, locale, cell phone.
- Now-dead fields `WS-SEND-SMS-PUSH-SW` / `WS-WILDFIRE-ZIP` (commented
  out under MEM-480330/MEM-480960 — see history below).

## Control Flow

1. **1000-INITIALIZE-ROUTINE**: opens files; **1100-GET-PROC-DATE** reads
   the single date-file record and splits it into ISO components;
   **1200-GET-NO-DAYS** calls `MD699BR` for club `'001'` to retrieve
   `MD23-REN-DUE-SMS-PUSH-DAYS` into `WS-SMS-DAYS` (comment notes all
   clubs currently share the same value, so club 001/"Alabama" is used
   as a stand-in — see ambiguity note); **1300-CALC-TARGET-DATE**
   computes `WS-TARGET-DATE = WS-PROC-DATE + WS-SMS-DAYS DAYS`; opens the
   cursor and performs the first fetch; writes the CSV header.
2. **2000-PROCESS-CURSOR** loops until end of cursor. For each row:
   - Builds the semicolon separators, extract date, expiration date,
     customer id, club code, locale, and message type (`'SMS'`).
   - Calls `MD999CK` for the 16-digit membership number.
   - **2001-CHECK-PIT**: as in `MD021EX`, calls `FN435BT` and sums any
     `'PIT '` payments; if there is a payment in transit the row is
     skipped and counted (`WS-PIT-COUNT`).
   - If no PIT: calls `MC501BCD` (2010) for first/last name and a
     qualifying cell phone (`role='CL'`, valid, non-expired). If no cell
     phone is on file, the row is skipped (`WS-NO-CELL-COUNT`).
   - If a cell phone exists: calls **3000-CHECK-CONSENT** (`MC556BR`); if
     not consented, skipped (`WS-NO-CONSENT-COUNT`).
   - If consented: calls **3100-AMOUNT-DUE** (`MD610BR`); if no amount is
     currently due, skipped (`WS-NO-AMOUNT-COUNT`); otherwise the amount
     due is formatted and the row is written to the output file
     (`2020-WRITE-OUTFILE`).
   - Fetches the next row and repeats.
3. **2050-EOF-ROUTINE**: displays detailed counts (input, skipped, PIT,
   no-cell, no-consent, no-amount, output) and closes the files.

## Modification History

| Date | Who | Description |
|---|---|---|
| 03/05/20 | Phil B | MEM-474915 — new program cloned from MD021EX |
| 07/01/20 | selina | MEM-475237 — change number of days to pull data; convert to business rules (`MD699BR`) to allow update without a code change |
| 09/22/21 | J. Frank | MEM-476424 — remove TX and NNE check for text messaging |
| 10/06/21 | J. Frank | MEM-476424 — revert the above removal |
| 01/16/25 | Kumar | MEM-480330 — added logic to block SMS/Push for selected CA zip codes (2025 wildfire response) |
| 06/11/25 | Praveena | MEM-480960 — removed the MEM-480330 wildfire changes |

Note: the MEM-480330 wildfire-blocking logic (zip-code check against a
hard-coded list, club `'004'`) is left in the source as commented-out
dead code rather than deleted; it is not currently active.

## Ambiguous / Environment-Dependent Notes

- `1200-GET-NO-DAYS` always passes club `'001'` to `MD699BR` regardless
  of the actual member's club, with an in-code comment explicitly
  acknowledging this is a shortcut because "at the moment all clubs have
  the same value" — if that business rule ever diverges by club, this
  program will compute the wrong target date for non-'001' clubs.
  This is a real (documented-in-source) limitation, not a translation
  artifact.
- Whether TX/NNE members are excluded from text messaging depends on
  whichever version of `MD699BR`'s underlying business-rule data is
  active at runtime — the club-level exclusion logic referenced by
  MEM-476424 lives outside this program.
- Output DD `MD022OP` consumer (SMS gateway/EBIZ) is external.
