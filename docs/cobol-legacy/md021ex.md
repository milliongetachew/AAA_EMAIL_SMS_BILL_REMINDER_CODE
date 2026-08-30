# MD021EX

Source: `attachments/M D 0 2 1 E X.txt`

## Summary

MD021EX is a batch extract program that produces a comma-delimited "mobile
notification subscriber" file of members who are in renewal, are **not**
on membership autopay (bill plan `AM`, i.e. manually billed), have a
membership payment due, and whose payment is not already "in transit"
(PIT). It selects members whose payment is due exactly 13 days from the
current processing date and writes one CSV row per eligible member,
including contact info looked up from the customer master. This file
feeds a downstream mobile/SMS notification subscriber list.

## Inputs and Outputs

- **Input file** `DATE-FILE` (DD `PROCDTIN`, `DATEREC` PIC X(80)): a
  single-record file supplying the batch processing date (`WS-PROC-DATE`).
- **Output file** `OUT-FILE` (DD `MD021OP`, `OUTREC` PIC X(198)): comma-delimited
  CSV, one header row (`WS-HEADER`) plus one detail row per selected member.
- **DB2 tables** (via DCLGEN `INCLUDE`): `MBRSHP_HOUSEHOLD` (`MBRHSHLD`),
  `MBR_PRD_DTL` (`MBRPRDDT`), `MBR_INFO`/`MEMBER` (`MEMBER`), plus `SQLCA`.
- **Cursor `CUSTID`**: joins `MBRSHP_HOUSEHOLD`, `MBR_PRD_DTL`, `MBR_INFO`
  where `CUR_TERM_EXP_D < REN_TERM_EXP_D` (member mid-renewal),
  `FK_BILL_PLAN_TYP_C = 'AM'` (manual/non-autopay), role `'00'`, currently
  effective rows (`EXP_D = '12/31/9999'`), `PAID_C = 'N'` (unpaid), and
  `EFF_D = :WS-TARGET-DATE` (target = process date + 13 days).
- **External subprograms called**: `FN435BT` (payment-in-transit / PIT
  check), `MC501BCD` (MACS customer data + phone lookup), `MD999CK`
  (converts short membership number to 16-digit check-digit format).
- **Copybooks**: `MAC501C` (MC501BCD linkage), `MRD021C` (output record
  layout), `MRD900C`/`MRD901C`/`MRD903C` (standard error-handling
  copybooks), `MRD999CK` (MD999CK linkage), `UTL000C` (current date
  utility), `FIN435C` (FN435BT commarea).

## Key Data Structures

- `WS-DATEREC` / `WS-PROC-DATE` (X(10)): the batch processing date read
  from the date file.
- `WS-HEADER`: fixed literal CSV header row — `MembershipNumber, CustID,
  MobileNumber, Locals, EmailAddress, SubcriberKey, FirstName`.
- `MC501-INPUT-OUTPUT` (copybook `MAC501C`): request/response area for the
  MACS customer subroutine; output fields used include first/last name,
  email + validity flag, and an array of phone numbers (`MC501-O-PH-*`,
  `OCCURS`) each with role, valid-code, expiration date, area code,
  prefix, suffix.
- `WS-OUTREC` (copybook `MRD021C`): the output CSV record — 16-digit
  membership number, customer ID, locale, email, subscriber key
  (duplicated from email), and cell phone (`1` flag + area/prefix/suffix
  packed into a string), separated by comma filler fields
  (`MD021-COMMA-01` … `06`).
- `FN435BT-COMMAREA` (copybook `FIN435C`): input/output area for the PIT
  (payment-in-transit) subroutine — an `OCCURS` table of up to 10 payments
  (`FIN435-O-PAYMNT-STATUS`, `FIN435-O-PAYMNT-AMOUNT`) is scanned for any
  with status `'PIT '`; if the summed amount is > 0 the member is
  considered to have a payment in transit and is skipped.
- `MD999-LINK-DATA` (copybook `MRD999CK`): input club/member/role, output
  16-digit check-digit membership number.

## Control Flow

1. **1000-INITIALIZE-ROUTINE**: opens files, reads the process date
   (1005), opens the `CUSTID` cursor (1015) and does the first fetch
   (1020); if the cursor is immediately empty or errors, the program
   abends. Writes the CSV header row.
2. **1005-GET-PROC-DATE**: reads the date file to end (single record
   expected), then uses `EXEC SQL SET` to compute
   `WS-TARGET-DATE = WS-PROC-DATE + 13 DAYS` (ISO format). Also captures
   the current wall-clock run date via `FUNCTION CURRENT-DATE` for
   display/logging.
3. **2000-PROCESS-CURSOR** loops until the cursor returns SQLCODE 100:
   for each fetched club/member/customer-id row it:
   - Calls `MD999CK` (2015) to get the 16-digit membership number.
   - Moves customer id and locale (`en-US`) into the output record.
   - Calls **2001-CHECK-PIT**: invokes `FN435BT`; return code `'000'`
     means payment data was found and `2005-CHECK-PIT-DETAIL` sums any
     `'PIT '` status payments (up to 10) to decide
     `MEMBER-HAS-PIT-YES/NO`; return code `'210'` means no payment data
     (treated as no PIT); any other code abends.
   - If the member has **no** PIT: calls `MC501BCD` (2010) to fetch first
     name, a valid email (only if `MC501-O-EMAIL-VALID-C = '1'`), and the
     first phone found with role `'CL'`, valid-code `'1'`, and expiration
     `99991231`, then writes the CSV row (2020) and increments the output
     counter.
   - If the member **has** a PIT, the row is skipped and counted
     (`WS-SKIPPED-COUNT`, implicitly via the `ELSE` branch).
   - Fetches the next cursor row and loops.
4. **2050-EOF-ROUTINE**: displays run totals (input/skipped/output) and
   closes both files.
5. Any SQL or subprogram error path moves diagnostic data into the
   standard `MD900-ERROR-DATA` area and performs `9999-ABEND`
   (`COPY MRD902C`, the shared abend routine).

## Modification History

From the header comment block:

| Date | Who | Description |
|---|---|---|
| 12/21/18 | MDIEP | WEB-18-50 — Mobile app push notification |
| 08/23/24 | RATHNA | MEM-479718 — Add first name to SMS & push file (adds `WS-FIRST-NAME` / `MD021-FIRST-NAME` and header column) |

## Ambiguous / Environment-Dependent Notes

- The date file (`PROCDTIN`) is expected to contain exactly one record;
  the read loop trusts that a single record supplies the processing date.
  Its upstream production (which job/step writes it) is not visible here.
- The 13-day offset is hard-coded in this program (unlike its sibling
  `MD022EX`, which reads the offset from business rules via `MD699BR`).
  Whether 13 is still the intended business value or a historical
  artifact is not determinable from source alone.
- `MD021OP` (output DD) consumer is external — presumably an EBIZ/mobile
  push subscriber feed — not documented in this source.
- Despite the header comment mentioning "MEMBER CUSTID IS ON TODAY LIST
  OF MOBILE NOTIFICATION SUBSCRIBER" as a requirement, no such
  subscriber-list check actually appears in the SQL or logic — this may
  be enforced by a downstream consumer rather than this program.
