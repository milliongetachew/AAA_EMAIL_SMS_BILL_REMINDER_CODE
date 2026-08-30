# MD134ML

Source: `attachments/MD134ML.txt`

## Summary

MD134ML generates email correspondence for members on a monthly-pay
("MP") membership bill plan, driven by an "EIP" (Electronic Information
Processing / correspondence engine) extract file. For each incoming EIP
record it consults a business-rules subroutine to decide whether an
email should actually be produced for that club/letter combination,
applies a special suppression rule for letter `139` when it was
web-self-service-triggered, and — if the email is to be sent — builds a
semicolon-delimited output record (billing amounts, name, renewal date
in prose form, years of membership, etc.) and, for letter 139, logs the
send in the member correspondence-history table.

## Inputs and Outputs

- **Input file** `EIP-FILE-IN` (DD `MDEIPIN`, PIC X(5500)): one record
  per correspondence candidate, copybook `MRDEIPC` (`EIP-DATA-REC`) —
  contains club/membership number, letter code, bill-plan, dues/past-dues
  amounts, pay-day-of-month, last-4 of autopay card, customer id, name
  fields (`MDEIP-MRD-NAME-FIRST/LAST/SUFFIX`, arrays), address/zip, join
  year, spinoff max age, and renewal/expiration date.
- **Output file** `EMAIL-FILE-OUT` (DD `MD134OP`, PIC X(350)): header
  record plus one semicolon-delimited detail record per email to be
  sent, copybook `MRD134C` (`MD134-RECORD`).
- **DB2**: `SQLCA`, `MBRSHP_MONTHLY_CHARGE_DTL` (DCLGEN `MBRMCDTL`) —
  queried only for the letter-139 web-suppression check.
- **External subprograms**: `MD930BR` (processing date), `MD920BR` (job
  name, for logging), `MD999CK` (16-digit membership number), `MD607BR`
  (determines whether/how a letter's correspondence should be produced —
  "letter processing path" business rules), and (MEM-481279) `MD300MA`
  (writes to the correspondence-history table).
- **Copybooks**: `MRDEIPC` (input layout), `MRD134C` (output layout),
  `MRD607C1` (MD607BR linkage), `MRD300C` (MD300MA / correspondence
  history linkage), `MRD900C`, `MRD901C`, `MRD903C`, `MRD930C`,
  `MRD999CK`.

## Key Data Structures

- `EIP-DATA-REC` (copybook `MRDEIPC`): the large (5500-byte) EIP
  correspondence-candidate record — includes `MDEIP-CLUB-C`,
  `MDEIP-MBRSHP-N`, `MDEIP-LETTER-C`, `MDEIP-BILL-PLAN`,
  `MDEIP-TOTAL-DUES-MP`/`MDEIP-TOTAL-PAST-DUES-MP`, `MDEIP-CUST-ID`,
  `MDEIP-ADDR-EMAIL`, `MDEIP-ADDR-ZIP`, `MDEIP-REN-TERM-EXP-D`,
  `MDEIP-PAY-DAY-OF-THE-MONTH`, `MDEIP-AUTOPAY-ACCT-LAST-4`, and
  `OCCURS`-based name/join-year arrays (`MDEIP-MRD-NAME-FIRST(1)`, etc. —
  index `(1)` suggests one household/primary-role slot is used).
- `MD607-INPUT-OUTPUT` (copybook `MRD607C1`): input club/letter/effective
  date; output `MD607-EMAIL-CORR-TYPE-C` (the correspondence/email type
  code to use), level-88 conditions `MD607-BILL-CORR-TYPE-ECORR`,
  `MD607-PROCESS-NEW`, `MD607-PROCESS-OLD`.
- `MD134-RECORD` (copybook `MRD134C`): the 20-field, semicolon-delimited
  output record — email type, extract month/day/year, club, membership
  number (short + 16-digit), expiration date, bill plan, monthly
  due/past due, pay-day-of-month, credit-card last 4, customer id, name
  suffix/first/last, email address, human-readable renewal date string,
  years-as-member, zip code, spinoff age.
- `MD300-RECORD` (copybook `MRD300C`, MEM-481279): input/output area for
  the correspondence-history update subroutine `MD300MA`.
- `WK-BEGIN-TS` / `WK-END-TS`: a full-day timestamp window (00:00:00 to
  23:59:59.999999) built from the batch processing date, used to bound
  the "was this triggered by a web change today" lookup.

## Control Flow

1. **A0000-INITIALIZE**: opens both files (aborts on any non-zero file
   status), gets the processing date (`MD930BR`, used to seed both
   `WK-BEGIN-TS`/`WK-END-TS`), gets the job name (`MD920BR`, for
   logging), writes the CSV header row (`A5000-WRITE-HEADER`, 20 column
   names), then reads the first EIP input record.
2. **B0000-PROCESS-EIP-RECS** loops until end of file on the EIP input:
   - **B0100-WILL-EMAIL-BE-PRODUCED**: calls `MD607BR` with the record's
     club, letter code, and effective date to get back the
     correspondence type and processing-path flags.
   - If `MD607-EMAIL-CORR-TYPE-C` is non-blank, the correspondence type
     is `ECORR` (email), `MD607-PROCESS-NEW` is set, and the EIP record
     has an email address:
     - Sets `SEND-EMAIL` to true.
     - If the letter code is `'139'`, performs
       **B0200-DO-NOT-SEND-EMAIL**: queries
       `MBRSHP_MONTHLY_CHARGE_DTL` for any `ADD`/`CANCEL` charge for the
       member, created **today**, by department section `'36  '` /
       user `'009999'` (the system's convention for "created on the
       web"); if any such row exists, `NOT-SEND-EMAIL` is set — this is
       the INC943560 rule: don't send letter-139 correspondence if the
       member just made the change themselves online.
     - If still flagged to send, performs **B1000-PRODUCE-EMAIL**.
   - Reads the next EIP input record and loops.
3. **B1000-PRODUCE-EMAIL**: builds the full output record —
   - Maps most EIP fields directly to `MD134-O-*` output fields.
   - Calls `MD999CK` for the 16-digit membership number.
   - Special-cases email type `MPNOAUTHPMT`: if there are past dues, the
     type is upgraded to `MPNOAUTHNOPMT`; otherwise `MPNOAUTH`.
   - Builds a human-readable renewal date string (`"January 15"`, etc.)
     from the expiration month/day via an `EVALUATE` over all 12 months.
   - Computes years-of-membership as (expiration year − AAA join year),
     floored at 1, right-justified into a 3-character field.
   - Computes a "spinoff age" as `MDEIP-SPINOFF-MAX-AGE + 1`.
   - Cleans any stray `;` characters out of the whole record (`INSPECT
     ... REPLACING ALL ';' BY SPACES`) before inserting the real `;`
     field separators, to avoid corrupting the delimited format.
   - Writes the detail record and increments the email counter.
   - **MEM-481279**: if the letter code was `'139'`, calls
     **B4000-UPDATE-CORR-HIST** with correspondence type `'639'` to log
     the send in the correspondence-history table via `MD300MA`.
4. **B4000-UPDATE-CORR-HIST**: populates `MD300-RECORD` (club, member
   number, send date = today, role `'00'`, correspondence type) and
   calls `MD300MA`; tolerates "member cancelled" / "member missing"
   (SQLCODE 100) as non-fatal (logs and continues), aborts on any other
   error.
5. **Z0000-CLOSE**: closes both files (aborts on bad file status),
   displays total input records read and total emails written.

## Modification History

| Date | Who | Description |
|---|---|---|
| 01/13/2017 | M Diep | Initial implementation |
| 04/03/2017 | M Diep | Recompile for new `MRDEIPC` |
| 07/18/2017 | s.w. | Recompile for new `MRDEIPC` |
| 06/21/2018 | M Diep | INC943560 — do not send email if letter 139 was triggered by web-originated changes |
| 02/14/2019 | Phil B | MEM-18-01C — add 4 fields and header (renewal date string, years-member, zip, spinoff age) |
| 12/04/2025 | Ranski | MEM-481279 — Membership Communication Visibility: update the correspondence-history table for all email correspondence |

## Ambiguous / Environment-Dependent Notes

- The web-origination check hard-codes department section `'36  '` and
  user id `'009999'` as the signature of a web-initiated change; the
  business meaning of these specific codes is not documented in this
  source and lives in whatever system assigns them.
- `MDEIP-MRD-NAME-FIRST(1)`, `MDEIP-MRD-AAA-JOIN-YEAR(1)`, etc. use a
  fixed index `(1)` into `OCCURS` arrays in the EIP record — this
  program only ever considers the first occurrence (presumably the
  primary member); the array's other slots (additional household
  members) are not used by this program.
- `B4000-UPDATE-CORR-HIST` is only invoked for letter `'139'`; other
  letter types processed by this program do not get a correspondence-
  history entry, despite MEM-481279's stated goal of updating history
  "for all email correspondence" — this may indicate the change is
  partially applied, or that other letter types are logged elsewhere;
  cannot be resolved from this source alone.
- Upstream production of `MDEIPIN` (which job/step builds the EIP
  extract, and on what schedule/filter) is outside this program.
