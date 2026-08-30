# MD022ZA

Source: `attachments/MD022ZA.txt`

## Summary

MD022ZA creates the "pre-auth ($0.00)" SMS and Push notification files
for members roughly 77 days before their membership expiration ("-77
days"), for consumption by EBIZ. Unlike the other `MD022*` programs, it
does not query DB2 for its member population directly — it reads a
pre-built extract file (already filtered upstream) and, for each record,
enriches it with customer contact data before writing the SMS/Push
output. It is explicitly documented as a clone of a `MD145A` program and
runs seven days a week.

## Inputs and Outputs

- **Input file** `ZA-EMAIL-FILE` (DD `IZAEMAIL`, PIC X(240)): pre-filtered
  member extract records, read into copybook `MRD573C` layout
  (`WS-INPUT-AREA` / `MD573-*` fields: club code, customer number,
  extract month/day/year).
- **Output files**: `SMS-FILE` (DD `OSMSFILE`, PIC X(120)) and
  `PUSH-FILE` (DD `OPSHFILE`, PIC X(120)).
- **Runtime parameter**: `WS-INTERVAL-DAYS` via `ACCEPT ... FROM SYSIN`
  — used only to compute a `WS-TARGET-DATE` that is displayed for
  logging; it does not drive any DB2 selection in this program since
  there is no cursor.
- **DB2**: only `SQLCA` is included; `EXEC SQL SET` is used purely for
  date arithmetic (`RUN-DATE`, `WS-TARGET-DATE`) and there is no query
  against membership tables.
- **External subprograms**: `MD930BR` (processing date), `MC501BCD`
  (customer data/phone), `MC556BR` (SMS consent).
- **Copybooks**: `MD022SP` (shared SMS+Push header/detail layout),
  `MRD573C` (input record layout), `MRD930C`, `MAC501C`, `MAC556C`,
  `MAC900C`, `MRD900C`, `MRD901C`, `MRD903C`.

## Key Data Structures

- `WS-INPUT-AREA` (copybook `MRD573C`): one input record per member —
  `MD573-CLUB-C`, `MD573-CUSTOMER-NBR`, `MD573-EXTR-MO/DY/YR`.
- `WS-SMS-PUSH-REC-AREAS` (copybook `MD022SP`): same shared SMS/Push
  header and detail layout used by `MD022LP`/`md022cc`.
- `WS-PHONE-NUMBER`, `MEMBER-CONSENT-SW`: as in the other `MD022*`
  programs.

## Control Flow

1. **1000-INITIALIZE-ROUTINE**: opens the input file and both output
   files, gets the processing date (`MD930BR`), computes a target date
   from the SYSIN interval (used for display/logging only), and writes
   SMS/Push header rows.
2. **2000-PROCESS-ZA-RECORDS** loops until end-of-file on the input
   extract: reads one `MRD573C` record; if not at end, performs
   **3000-GENERATE-SMS-PUSH**.
3. **3000-GENERATE-SMS-PUSH**:
   - **4000-CALL-MC501BCD**: looks up first name and a qualifying cell
     phone for `MD573-CUSTOMER-NBR`.
   - If a phone was found, **4100-CHECK-CONSENT** calls `MC556BR`.
   - If consented, **5000-WRITE-SMS-RECORD** writes the SMS detail
     record, using the extract date from the **input file**
     (`MD573-EXTR-MO/DY/YR`, reformatted `MM/DD/YYYY`) rather than the
     batch processing date.
   - **6000-WRITE-PUSH-RECORD** is performed unconditionally for every
     input record (independent of phone/consent outcome), also using the
     input file's extract date.
4. **9999-FINAL-RTN**: closes all three files and displays
   extracted/SMS-written/Push-written counts.

## Modification History

| Date | Ticket | Description | By |
|---|---|---|---|
| 05/12/2022 | (new) | Initial creation | A. Sum |
| 08/23/2024 | MEM-479718 | Add first name to SMS and Push file | Rathna R |

## Ambiguous / Environment-Dependent Notes

- This program has no membership-eligibility SQL of its own — all
  eligibility filtering (renewal window "-77 days", club/campaign
  restrictions, etc.) happens in whatever upstream job populates
  `IZAEMAIL`. That upstream job is not part of this file set and its
  logic cannot be verified from this source alone.
- The header explicitly states this is "a clone of the MD145A program";
  `MD145A` was not among the files provided for this review, so the
  original business rules it was cloned from cannot be cross-checked.
- `6000-WRITE-PUSH-RECORD` always executes for every input record
  regardless of whether a phone was found or consent was given — Push
  notifications here appear to be sent purely based on the member being
  present in the upstream `-77 day` extract file.
- `WS-TARGET-DATE`/`WS-INTERVAL-DAYS` are computed but not otherwise used
  in the logic (no cursor, no filtering) — they appear to be vestigial
  from the shared program template and only affect the startup log
  display.
