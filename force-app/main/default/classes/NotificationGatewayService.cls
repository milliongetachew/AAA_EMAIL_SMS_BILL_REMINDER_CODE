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
 * channel (.txt or .csv, per program — see docs/cobol-legacy/*.md) that
 * feeds into the same AFT/MOVEit pipeline that picked up `OSMSFILE`,
 * `OUTSMS`, `MD572O1`, etc. in the legacy pipeline.
 *
 * SECOND CORRECTION — real AFT/Control-M job configuration confirmed (see
 * docs/salesforce-design/moveit-aft-reference.md for the full evidence):
 * that pipeline is TWO STAGES, and MOVEit is a relay, not the system that
 * encrypts or the final destination.
 *   Stage 1 ("O" job) — a plaintext file lands in a local staging path
 *     (mainframe-local today; e.g. `%%PGPTemp.\MRD\...` on host `gid01943`).
 *   Stage 2 ("E" job, "Encrypted File Transfer Job") — a SEPARATE, already-
 *     existing AFT job PGP-encrypts that file CLIENT-SIDE, before it ever
 *     reaches MOVEit, then transfers the already-encrypted file to MOVEit
 *     (`/users/SMSPUSH/OUTBOUND/`) and deletes the plaintext source.
 * The PGP key observed (`salesforce-prod-042325-1 (sfmc xfer)`, vendor
 * `SalesForce`) plus SFMC MobileConnect-specific column names in the real
 * SMS extract (`SubscriberKey`, `Locale`) make it near-certain the real
 * final consumer past MOVEit is Salesforce Marketing Cloud — strongly
 * indicated, not 100% confirmed.
 *
 * This class therefore does two things, corresponding to the queue/flush
 * pattern — but see the UNRESOLVED note under constraint (2) below for what
 * flush() actually needs to call, which is genuinely open, not a corrected
 * guess:
 *   1. queueSms()/queuePush()/queueEmail() — append a row to today's
 *      in-memory extract for that channel (replaces a single
 *      WRITE SMS-RECORD / WRITE PUSH-RECORD / WRITE EMAIL-RECORD).
 *   2. flush() — called ONCE per batch run (from Batch Apex's finish(), or
 *      at the end of a Queueable's execute()), assembles each channel's
 *      buffered rows into a file body and uploads it via a single HTTPS
 *      callout per channel to wherever this pipeline's plaintext hand-off
 *      point turns out to be (replaces CLOSE OUTPUT-FILE + the downstream
 *      job's file pickup) — NOT necessarily a direct MOVEit API call; see
 *      constraint (2).
 *
 * TWO CONSTRAINTS THIS CLASS DELIBERATELY DOES NOT TRY TO WORK AROUND:
 *
 *  (1) PGP ENCRYPTION IS OUT OF SCOPE FOR APEX — AND, per the real job
 *      config, it doesn't need to be. Apex has no native OpenPGP/PGP
 *      message-format implementation — Crypto.encrypt()/
 *      encryptWithManagedIV() are raw AES/RSA primitives, not the OpenPGP
 *      container format the downstream pipeline expects — but that gap is
 *      moot: PGP encryption already happens OUTSIDE Salesforce entirely, in
 *      the existing Stage 2 "Encrypted File Transfer" AFT job, client-side,
 *      BEFORE the file ever reaches MOVEit (see the two-stage model above).
 *      This class's job is only to produce the PLAINTEXT extract and get it
 *      to wherever that existing pipeline's input point is; do not attempt
 *      to PGP-encrypt anything in Apex, and do not assume MOVEit itself
 *      applies PGP after this class's upload — the real pipeline shows
 *      MOVEit only ever receiving an already-encrypted file.
 *
 *  (2) NO SFTP FROM APEX, AND NO CONFIRMED DIRECT-TO-MOVEIT HANDOFF EITHER.
 *      Apex has no raw socket / SFTP client — only HTTP(S) callouts — and it
 *      cannot write to a Windows/mainframe-local file share the way the
 *      real Stage 1 AFT job does. UNRESOLVED, same rigor as the PGP flag
 *      above: how this class's plaintext extract actually reaches the
 *      AFT/MOVEit pipeline has NOT been confirmed, and it is very unlikely
 *      to be a direct MOVEit REST "upload file" call — the real pipeline
 *      shows MOVEit receiving files only AFTER the Stage 2 encrypt job has
 *      already run, not receiving a Salesforce-originated plaintext file
 *      directly. Whether the real hand-off is an HTTPS endpoint the
 *      AFT/integration layer exposes for Salesforce-originated files, or
 *      some other mechanism entirely, needs confirmation from the
 *      AFT/MOVEit/integration team before implementation.
 *      `uploadChannelFile()` below assumes a generic "PUT raw file body to
 *      a folder-scoped HTTPS endpoint" shape as a PLACEHOLDER ONLY, standing
 *      in for whatever that real hand-off point turns out to be — do not
 *      treat `MOVEIT_NAMED_CREDENTIAL`/`MOVEIT_UPLOAD_PATH` as a confirmed
 *      API contract, and do not replace them with a different but equally
 *      invented shape without that confirmation.
 *
 * FILE FORMAT: per docs/cobol-legacy/*.md, the legacy programs did NOT use
 * one consistent format — `MD021EX` wrote comma-delimited CSV
 * (`OUT-FILE`/`MD021OP`), `MD134ML` and `MD572EM` wrote semicolon-delimited
 * text (`MD134OP`, `MD572O1`), and the `MD022EX`/`MD022ER`/`MD022EC`/
 * `MD022LP`/`md022cc` (`OSMSFILE`) and `MD058CB` (`OUTSMS`/`OUTPSH`/
 * `OUTEML`) families wrote FIXED-WIDTH `PIC X(nnn)` records per the reviewed
 * source. Real current sample output files (see
 * docs/salesforce-design/moveit-aft-reference.md "Real output file
 * layouts") now confirm the ACTUAL current column layouts for three of
 * these channels — SMS/Push (9 columns), Email (11 columns), and MD058CB's
 * CAU email sub-format (8 columns, semicolon-delimited AND space-padded to
 * a fixed width per field, a hybrid format) — see `SMS_PUSH_COLUMNS`,
 * `EMAIL_COLUMNS`, and `CAU_EMAIL_COLUMNS` below, which replace the earlier
 * illustrative/guessed shapes for those programs. Column order matters if
 * the downstream SFMC import is positional rather than header-mapped —
 * NOT confirmed either way; do not assume header-based mapping is safe.
 * This scaffold implements only a generic comma/semicolon DELIMITED writer
 * (see `DELIMITER_BY_PROGRAM` below); it does NOT implement the CAU hybrid
 * fixed-width-plus-delimiter padding, and it does NOT implement fixed-width
 * formatting for any program/channel not covered by the three real samples
 * above (notably `MD058CB`'s SMS/Push channels, and `MD022*`'s original
 * `PIC X(nnn)` layout if it differs from the now-confirmed real CSV shape)
 * — those gaps need a dedicated formatter built from the relevant copybooks
 * (`MRD058SF`/`MRD058PF`/`MRD058EF`, etc.) or further real-sample
 * confirmation before cutover for those specific programs/channels.
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

    // UNRESOLVED — placeholder Named Credential name, standing in for
    // whatever the real AFT/MOVEit pipeline hand-off point turns out to be.
    // Per the real two-stage AFT job config (see class header, constraint
    // 2, and docs/salesforce-design/moveit-aft-reference.md), this is very
    // unlikely to be a direct MOVEit API — MOVEit only ever receives a file
    // AFTER a separate, already-existing "Encrypted File Transfer" AFT job
    // has PGP-encrypted it. Confirm the real hand-off target with the
    // AFT/integration team before implementation.
    private static final String MOVEIT_NAMED_CREDENTIAL = 'callout:MOVEit_MFT';

    // UNRESOLVED — placeholder upload path/shape; see class header,
    // constraint 2. Do not treat this as a confirmed API contract.
    private static final String MOVEIT_UPLOAD_PATH = '/api/v1/folders/UNCONFIRMED_FOLDER_ID/files';

    // Real, confirmed CURRENT column layouts, from actual sample output
    // files (see docs/salesforce-design/moveit-aft-reference.md "Real
    // output file layouts"). These REPLACE any earlier illustrative/guessed
    // shape for the programs/channels they apply to. Column order matters
    // if the downstream SFMC import is positional rather than header-mapped
    // — NOT confirmed either way.
    //
    // SMS/Push extract — applies to the MD021EX/MD022* "OSMSFILE" family
    // (MD021EX, MD022EX, MD022ER, MD022EC, MD022LP, md022cc, MD022ZA).
    // Verified against a real sample for MD021EX-generated output; the rest
    // of the MD022* family is assumed to share this real layout based on
    // the shared AFT staging-filename convention
    // (MRDPN.MD021/MD022.PUSH|SMS.*), but that has NOT been verified
    // per-program the way the MD021EX sample was — confirm before relying
    // on it for those specifically.
    private static final List<String> SMS_PUSH_COLUMNS = new List<String>{
        'SubscriberKey', 'MobileNumber', 'Locale', 'CustId', 'ClubCode',
        'Membership#', 'ExpirationDt', 'FirstName', 'Zipcode'
    };
    // Email extract — applies to the MD134ML/MD572EM semicolon-delimited
    // family.
    private static final List<String> EMAIL_COLUMNS = new List<String>{
        'EmailAddress', 'CustID', 'ClubCode', 'State', 'FirstName',
        'LastName', 'Membership Level', 'CellName', 'Zip',
        'MembershipNumber', 'ExpirationDate'
    };
    // CAU email layout — belongs specifically to MD058CB's EMAIL channel
    // (not its SMS/Push channels, which remain an unconfirmed fixed-width
    // gap — see class header). Semicolon-delimited AND each field is
    // space-padded to a fixed width before the delimiter — a hybrid
    // fixed-width/delimited format. NOT representable by the plain
    // delimited buildFileBody() writer below as-is; the padding behavior is
    // NOT implemented here. Rows with a blank EmailAddress are valid in the
    // real sample (paired with a legacy `000NNNNNN999901`-style CustId) and
    // must still be emitted, not filtered out, unless the business says
    // otherwise.
    private static final List<String> CAU_EMAIL_COLUMNS = new List<String>{
        'EmailAddress', 'CustId', 'ClubCode', 'FirstName', 'Zipcode',
        'MembershipNumber', 'ExpirationDate', 'Last4Digits'
    };

    // Delimiter used by each legacy program's flat-file format. Programs
    // not listed here (notably MD058CB, and any MD022* program not yet
    // individually verified against a real sample — see SMS_PUSH_COLUMNS
    // above) used FIXED-WIDTH or hybrid records and are NOT correctly
    // represented by this generic delimited writer — see class header.
    private static final Map<String, String> DELIMITER_BY_PROGRAM = new Map<String, String>{
        // SMS/Push real layout confirmed — SMS_PUSH_COLUMNS above.
        'MD021EX' => ',',  // OUT-FILE / MD021OP — verified against real sample
        'MD022EX' => ',',
        'MD022ER' => ',',
        'MD022EC' => ',',
        'MD022LP' => ',',
        'md022cc' => ',',
        'MD022ZA' => ',',
        // Email real layout confirmed — EMAIL_COLUMNS above.
        'MD134ML' => ';',  // EMAIL-FILE-OUT / MD134OP
        'MD572EM' => ';'   // EMAIL-FILE-OUT / MD572O1
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
     * matters to the downstream consumer. `SMS_PUSH_COLUMNS`/
     * `EMAIL_COLUMNS`/`CAU_EMAIL_COLUMNS` above document the real,
     * confirmed column order for the programs they cover and are the
     * intended source for that explicit ordered field list — callers
     * queueing rows for those programs should build their merge-field maps
     * in that column order rather than relying on this method to reorder
     * them. This method does not yet enforce that order itself, and does
     * NOT implement the CAU family's fixed-width space-padding.
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
