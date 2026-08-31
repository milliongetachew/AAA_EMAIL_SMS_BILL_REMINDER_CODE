/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §4 for the integration
 * architecture this class implements.
 *
 * CORRECTED MODEL (see high-level-design.md §4 changelog note): the
 * downstream delivery mechanism is NOT a live per-message SMS/push/email
 * provider API. It is the same flat-file hand-off pattern the legacy COBOL
 * programs already used — build up SMS-RECORD/PUSH-RECORD/EMAIL-RECORD rows
 * in memory over the course of a run, then write ONE extract file per
 * channel (.txt or .csv, per program — see docs/cobol-legacy/*.md) that is
 * delivered via MOVEit (a managed file transfer / MFT product) to a shared
 * folder, where the actual downstream SMS gateway / push service / EBIZ-EIP
 * email processor picks it up — exactly like `OSMSFILE`, `OUTSMS`,
 * `MD572O1`, etc. were picked up by a separate job in the legacy pipeline.
 *
 * This class therefore does two things, corresponding to that two-step
 * legacy pattern:
 *   1. queueSms()/queuePush()/queueEmail() — append a row to today's
 *      in-memory extract for that channel (replaces a single
 *      WRITE SMS-RECORD / WRITE PUSH-RECORD / WRITE EMAIL-RECORD).
 *   2. flush() — called ONCE per batch run (from Batch Apex's finish(), or
 *      at the end of a Queueable's execute()), assembles each channel's
 *      buffered rows into a file body and uploads it to MOVEit via a single
 *      HTTPS callout per channel (replaces CLOSE OUTPUT-FILE + the
 *      downstream job's file pickup).
 *
 * TWO CONSTRAINTS THIS CLASS DELIBERATELY DOES NOT TRY TO WORK AROUND:
 *
 *  (1) PGP ENCRYPTION IS OUT OF SCOPE FOR APEX. Apex has no native OpenPGP/
 *      PGP message-format implementation — Crypto.encrypt()/
 *      encryptWithManagedIV() are raw AES/RSA primitives, not the OpenPGP
 *      container format MOVEit-consuming systems expect. The recommended
 *      default is that MOVEit Automation (or whichever MOVEit product tier
 *      is in use) applies PGP encryption SERVER-SIDE, as a workflow step
 *      after this class uploads the PLAINTEXT extract file — this is
 *      standard MFT-platform functionality and keeps Apex out of the PGP
 *      business entirely. The files this class builds and uploads are
 *      therefore plaintext; do not attempt to PGP-encrypt them in Apex.
 *      FALLBACK ONLY (do not default to this): if the business specifically
 *      requires encryption-in-transit-FROM-Salesforce (i.e. MOVEit must
 *      never see plaintext), that requires either a middleware hop that
 *      PGP-encrypts before handing off to MOVEit, or an AppExchange PGP
 *      package — neither is implemented here, and this should only be
 *      pursued if explicitly required.
 *
 *  (2) NO SFTP FROM APEX. Apex has no raw socket / SFTP client — only
 *      HTTP(S) callouts. So the Salesforce → MOVEit handoff MUST go through
 *      a MOVEit REST/HTTPS upload API via Named Credential, never SFTP
 *      directly from this class. UNRESOLVED: the exact MOVEit product/API
 *      surface in use — MOVEit Transfer's REST "upload file" API, a MOVEit
 *      Automation task trigger endpoint, or an integration-platform
 *      (MuleSoft/etc.) hop that itself talks SFTP/MOVEit on Salesforce's
 *      behalf — has NOT been confirmed. `uploadChannelFile()` below assumes
 *      a generic "PUT raw file body to a folder-scoped HTTPS endpoint"
 *      shape as a placeholder ONLY; the Named Credential name, endpoint
 *      path, HTTP method, auth scheme, and request/response payload shape
 *      must all be confirmed with the MOVEit/integration team before this
 *      can be implemented for real.
 *
 * FILE FORMAT: per docs/cobol-legacy/*.md, the legacy programs did NOT use
 * one consistent format — `MD021EX` wrote comma-delimited CSV
 * (`OUT-FILE`/`MD021OP`), `MD134ML` and `MD572EM` wrote semicolon-delimited
 * text (`MD134OP`, `MD572O1`), and the `MD022EX`/`MD022ER`/`MD022EC`/
 * `MD022LP`/`md022cc` (`OSMSFILE`) and `MD058CB` (`OUTSMS`/`OUTPSH`/
 * `OUTEML`) families wrote FIXED-WIDTH `PIC X(nnn)` records. Since the
 * downstream consumer of these files is not changing, the safest default is
 * to replicate each legacy program's existing record layout rather than
 * inventing a new shape. This scaffold implements only a generic
 * comma/semicolon DELIMITED writer (see `DELIMITER_BY_PROGRAM` below) as a
 * placeholder for the delimited-format programs; it does NOT implement
 * fixed-width formatting for the `MD022*`/`MD058CB` families — that needs a
 * dedicated fixed-width formatter built from those programs' exact
 * copybooks (`MRD058SF`/`MRD058PF`/`MRD058EF`, etc.) before cutover for
 * those specific programs. A clean, modernized CSV shape (dropping the
 * legacy layout entirely) is a possible FUTURE-phase option, but only once
 * the downstream consumer system itself is revisited — do not do this by
 * default.
 *
 * GOVERNOR-LIMIT NOTE (revised): the old "100 callouts per transaction"
 * concern from the per-message-callout design no longer applies the same
 * way. Sends are now batched into (at most) one file-upload callout per
 * channel per run, not one callout per record — so a batch scope of
 * thousands of rows still produces only a handful of callouts (one per
 * channel actually used, on the single flush() call), not one per row.
 * The relevant limits to watch instead are heap size (rows/file body held
 * in memory for the whole run — an argument for keeping
 * `Database.Stateful` batch scope sizes reasonable) and the per-callout
 * request body size limit (6 MB synchronous / 12 MB via Continuation or
 * async callouts) if a single day's extract could get large.
 */
public with sharing class NotificationGatewayService {

    public enum Channel { SMS, PUSH, EMAIL }

    public class QueueResult {
        public Boolean queued;
        public String errorMessage;
    }

    public class FlushResult {
        public String channel;
        public String fileName;
        public Integer rowCount;
        public Boolean success;
        public String errorMessage;
    }

    // UNRESOLVED — placeholder Named Credential name; confirm the real one
    // with the MOVEit/integration team (see class header, constraint 2).
    private static final String MOVEIT_NAMED_CREDENTIAL = 'callout:MOVEit_MFT';

    // UNRESOLVED — placeholder upload path/shape; see class header,
    // constraint 2. Do not treat this as a confirmed API contract.
    private static final String MOVEIT_UPLOAD_PATH = '/api/v1/folders/UNCONFIRMED_FOLDER_ID/files';

    // Delimiter used by each legacy program's flat-file format, per
    // docs/cobol-legacy/*.md (see class header FILE FORMAT note). Programs
    // not listed here used FIXED-WIDTH records and are NOT correctly
    // represented by this generic delimited writer — see class header.
    private static final Map<String, String> DELIMITER_BY_PROGRAM = new Map<String, String>{
        'MD021EX' => ',',  // OUT-FILE / MD021OP — comma-delimited CSV
        'MD134ML' => ';',  // EMAIL-FILE-OUT / MD134OP — semicolon-delimited
        'MD572EM' => ';'   // EMAIL-FILE-OUT / MD572O1 — semicolon-delimited
    };
    private static final String DEFAULT_DELIMITER = ',';

    private final String sourceProgram;

    private final Map<Channel, List<Map<String, Object>>> rowsByChannel = new Map<Channel, List<Map<String, Object>>>{
        Channel.SMS => new List<Map<String, Object>>(),
        Channel.PUSH => new List<Map<String, Object>>(),
        Channel.EMAIL => new List<Map<String, Object>>()
    };

    /**
     * @param sourceProgram Legacy program traceability label (e.g.
     *   'MD021EX', 'MD058CB') — drives both the output file naming and the
     *   delimiter lookup above. Pass null only in tests that never call
     *   flush() with queued rows.
     */
    public NotificationGatewayService(String sourceProgram) {
        this.sourceProgram = sourceProgram;
    }

    /**
     * Appends one SMS row to today's in-memory SMS extract. Replaces the
     * SMS output-file writes in MD021EX (2020-WRITE-OUTFILE), MD022EX/
     * MD022ER (2020-WRITE-OUTFILE / W0000-WRITE-OUTFILE), MD022EC/MD022LP/
     * md022cc (4000-WRITE-SMS-RECORD), and MD058CB (1930/1940 SMS record
     * build). Does NOT perform a callout — call flush() once per run.
     */
    public QueueResult queueSms(String toPhoneE164, String templateCode, Map<String, Object> mergeFields) {
        Map<String, Object> row = new Map<String, Object>{ 'to' => toPhoneE164, 'templateCode' => templateCode };
        if (mergeFields != null) {
            row.putAll(mergeFields);
        }
        return queue(Channel.SMS, row, String.isBlank(toPhoneE164));
    }

    /**
     * Appends one Push row to today's in-memory Push extract. Replaces the
     * Push output-file writes in MD022ER (W1000-WRITE-PUSH-FILE), MD022LP/
     * md022cc/MD022ZA (5000-WRITE-PUSH-RECORD / 6000-WRITE-PUSH-RECORD),
     * and MD058CB (1910/1920 Push record build). Does NOT perform a
     * callout — call flush() once per run.
     */
    public QueueResult queuePush(String subscriberKey, String templateCode, Map<String, Object> mergeFields) {
        Map<String, Object> row = new Map<String, Object>{ 'subscriberKey' => subscriberKey, 'templateCode' => templateCode };
        if (mergeFields != null) {
            row.putAll(mergeFields);
        }
        return queue(Channel.PUSH, row, String.isBlank(subscriberKey));
    }

    /**
     * Appends one Email row to today's in-memory Email extract. Replaces
     * the email output-file writes in MD134ML (B1000-PRODUCE-EMAIL),
     * MD572EM (B6000-WRITE-EMAIL-REC), and MD058CB (1950/1960 Email record
     * build). Does NOT perform a callout — call flush() once per run.
     */
    public QueueResult queueEmail(String toAddress, String templateCode, Map<String, Object> mergeFields) {
        Map<String, Object> row = new Map<String, Object>{ 'to' => toAddress, 'templateCode' => templateCode };
        if (mergeFields != null) {
            row.putAll(mergeFields);
        }
        return queue(Channel.EMAIL, row, String.isBlank(toAddress));
    }

    /**
     * Assembles and uploads one file per channel that has queued rows.
     * Call exactly once per batch run — from Database.Batchable's finish()
     * (not execute(), so multi-scope runs produce one file, not one per
     * scope), or at the end of a Queueable's execute(). Clears all buffers
     * afterward, whether or not the upload succeeded (matching the legacy
     * program's CLOSE OUTPUT-FILE — a run's records are not retried by
     * re-appending to the next run's file).
     */
    public List<FlushResult> flush() {
        List<FlushResult> results = new List<FlushResult>();
        for (Channel channel : new List<Channel>{ Channel.SMS, Channel.PUSH, Channel.EMAIL }) {
            List<Map<String, Object>> rows = rowsByChannel.get(channel);
            if (!rows.isEmpty()) {
                results.add(uploadChannelFile(channel, rows));
            }
        }
        for (List<Map<String, Object>> rows : rowsByChannel.values()) {
            rows.clear();
        }
        return results;
    }

    public Integer pendingCount(Channel channel) {
        return rowsByChannel.get(channel).size();
    }

    private QueueResult queue(Channel channel, Map<String, Object> row, Boolean missingRequiredDestination) {
        QueueResult result = new QueueResult();
        if (missingRequiredDestination) {
            result.queued = false;
            result.errorMessage = 'Missing required destination for ' + channel.name() + ' row — not added to extract';
            return result;
        }
        rowsByChannel.get(channel).add(row);
        result.queued = true;
        return result;
    }

    @TestVisible
    private FlushResult uploadChannelFile(Channel channel, List<Map<String, Object>> rows) {
        FlushResult result = new FlushResult();
        result.channel = channel.name();
        result.rowCount = rows.size();

        String delimiter = DELIMITER_BY_PROGRAM.containsKey(sourceProgram) ? DELIMITER_BY_PROGRAM.get(sourceProgram) : DEFAULT_DELIMITER;
        String extension = delimiter == ',' ? 'csv' : 'txt';
        String fileBody = buildFileBody(rows, delimiter);
        result.fileName = (sourceProgram == null ? 'UNKNOWN' : sourceProgram) + '_' + channel.name() + '_'
                + Datetime.now().format('yyyyMMdd_HHmmss') + '.' + extension;

        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(MOVEIT_NAMED_CREDENTIAL + MOVEIT_UPLOAD_PATH
                    + '?fileName=' + EncodingUtil.urlEncode(result.fileName, 'UTF-8'));
            req.setMethod('PUT');
            req.setHeader('Content-Type', delimiter == ',' ? 'text/csv' : 'text/plain');
            req.setBodyAsBlob(Blob.valueOf(fileBody));
            req.setTimeout(120000);

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                result.success = true;
            } else {
                result.success = false;
                result.errorMessage = 'HTTP ' + res.getStatusCode() + ': ' + res.getBody();
            }
        } catch (Exception ex) {
            result.success = false;
            result.errorMessage = ex.getMessage();
        }
        return result;
    }

    /**
     * Placeholder delimited-row formatter — see class header FILE FORMAT
     * note. Header columns are taken from the first row's key order, which
     * is stable within a single channel/run since every queueX() call for a
     * given source program builds rows with the same shape. NOTE: this
     * relies on Map<String,Object> preserving insertion order, which is a
     * long-standing Apex runtime behavior but is not a documented
     * guarantee — a production formatter should use an explicit ordered
     * field list per source program rather than trusting map iteration
     * order, especially for any program where exact legacy column order
     * matters to the downstream consumer.
     */
    @TestVisible
    private String buildFileBody(List<Map<String, Object>> rows, String delimiter) {
        List<String> headerKeys = new List<String>(rows[0].keySet());
        List<String> lines = new List<String>{ String.join(headerKeys, delimiter) };
        for (Map<String, Object> row : rows) {
            List<String> values = new List<String>();
            for (String key : headerKeys) {
                Object value = row.get(key);
                values.add(escapeField(value == null ? '' : String.valueOf(value), delimiter));
            }
            lines.add(String.join(values, delimiter));
        }
        return String.join(lines, '\n') + '\n';
    }

    private String escapeField(String value, String delimiter) {
        if (value.contains(delimiter) || value.contains('\n') || value.contains('"')) {
            return '"' + value.replace('"', '""') + '"';
        }
        return value;
    }
}
