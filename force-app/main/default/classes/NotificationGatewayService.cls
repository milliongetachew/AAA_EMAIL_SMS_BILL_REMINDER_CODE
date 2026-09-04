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
 * that pipeline is TWO STAGES.
 *   Stage 1 ("O" job) — a plaintext file lands in a local staging path
 *     (mainframe-local today; e.g. `%%PGPTemp.\MRD\...` on host `gid01943`).
 *   Stage 2 ("E" job, "Encrypted File Transfer Job") — PGP-encrypts the
 *     Stage 1 file and transfers the encrypted result to MOVEit
 *     (`/users/SMSPUSH/OUTBOUND/`), deleting the plaintext source.
 * The PGP key observed (`salesforce-prod-042325-1 (sfmc xfer)`, vendor
 * `SalesForce`) plus SFMC MobileConnect-specific column names in the real
 * SMS extract (`SubscriberKey`, `Locale`) make it near-certain the real
 * final consumer past MOVEit is Salesforce Marketing Cloud — strongly
 * indicated, not 100% confirmed.
 *
 * THIRD CORRECTION (user-confirmed 2026-09-01): MOVEit itself is capable of
 * PGP encryption. This means the Stage 2 "Encrypted File Transfer Job"
 * above may well be MOVEit's own automation engine executing the
 * `PUB_SalesForce`-keyed encryption task directly, not a separate
 * non-MOVEit system chained in front of it. That makes the most concrete
 * integration path: Apex uploads a plaintext file directly to a
 * MOVEit-exposed HTTPS endpoint via Named Credential, and MOVEit's own
 * automation applies PGP encryption and forwards the result onward (very
 * plausibly still to SFMC) — this is now the leading candidate for the
 * hand-off mechanism, not one of several equally-uncertain options.
 *
 * FOURTH CORRECTION (2026-09-04): a real, working Apex class from
 * elsewhere in this org (`AMSMoveitDynamicRouter`, shared by the user)
 * confirms the ENDPOINT SHAPE for exactly this kind of integration —
 * Named Credential `callout:MOVEit_Server`, endpoint
 * `/api/v1/folders/{folderId}/files`, POST as `multipart/form-data` with
 * three parts: `source` (a path string), `dest` (a path string), and
 * `file` (the file content). This is no longer a guess; it is a proven
 * pattern already used for a Salesforce-to-MOVEit integration in this org
 * (a different, unrelated data flow — see `uploadChannelFile()` below for
 * what's still unconfirmed for OUR channels specifically).
 *
 * That reference class also contains a real bug worth flagging regardless
 * of whether it's ever adopted here: its `combineMultipartBlob()` helper
 * base64-encodes the header text, file bytes, and footer text SEPARATELY
 * and concatenates the three encoded strings before base64-decoding the
 * result. That does not reconstruct the original bytes correctly — base64
 * only concatenates cleanly across a boundary when the byte length of
 * every piece before the last is an exact multiple of 3; arbitrary text/
 * file content will not satisfy that, so the reassembled body would be
 * corrupted in practice. This class avoids the bug entirely by building
 * the whole multipart body as ONE string (see `buildMoveitUploadRequest()`)
 * and converting to a `Blob` exactly once — safe here because every
 * channel's file content is plain text (CSV/semicolon-delimited), never
 * true binary; a channel that ever needed real binary content would need
 * different handling, not this same shortcut.
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
 *  (1) PGP ENCRYPTION IS OUT OF SCOPE FOR APEX — it doesn't need to
 *      implement it. Apex has no native OpenPGP/PGP message-format
 *      implementation — Crypto.encrypt()/encryptWithManagedIV() are raw
 *      AES/RSA primitives, not the OpenPGP container format the downstream
 *      pipeline expects — but that gap is moot: PGP encryption already
 *      happens OUTSIDE Apex, either in a separate Stage 2 "Encrypted File
 *      Transfer" AFT job, or — per the user-confirmed update (see the third
 *      correction above and moveit-aft-reference.md) — plausibly by
 *      MOVEit's own automation engine running that same Stage 2 task
 *      directly. This class's job is only to produce the PLAINTEXT extract
 *      and get it to wherever that existing pipeline's input point is; do
 *      not attempt to PGP-encrypt anything in Apex either way. Whether
 *      MOVEit itself applies PGP after this class's upload (now the leading
 *      candidate) or a separate job encrypts before MOVEit ever sees the
 *      file is the open hand-off question addressed in constraint (2).
 *
 *  (2) NO SFTP FROM APEX. Apex has no raw socket / SFTP client — only
 *      HTTP(S) callouts — and it cannot write to a Windows/mainframe-local
 *      file share the way the real Stage 1 AFT job does. The ENDPOINT SHAPE
 *      is now confirmed (see fourth correction above): Named Credential
 *      `callout:MOVEit_Server`, `POST /api/v1/folders/{folderId}/files`,
 *      multipart/form-data with `source`/`dest`/`file` parts. What remains
 *      UNCONFIRMED for OUR SMS/Push/Email/CAU channels specifically:
 *        - the real `folderId` for our pipeline (the reference example's
 *          folder belongs to an unrelated integration),
 *        - the real `source`/`dest` path VALUES our channels should send
 *          (the reference example's values — `%%PGPTemp.\MRD\aaa1ACE.in` /
 *          `/Users/Zipxmtm_CA_to_telematch/Transmit/` — are for that
 *          unrelated integration, not ours; do not reuse them literally),
 *        - whether this endpoint is the SAME one the existing Stage 1/Stage
 *          2 AFT jobs feed into, or a parallel route that needs its own
 *          provisioning for Salesforce-originated files.
 *      Get these three answers from the AFT/MOVEit/integration team before
 *      treating `MOVEIT_FOLDER_ID` and the `source`/`dest` placeholders in
 *      `buildMoveitUploadRequest()` below as anything but placeholders.
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

    // CONFIRMED endpoint shape (see class header, fourth correction) via a
    // real working example elsewhere in this org (AMSMoveitDynamicRouter).
    // The Named Credential name itself is a placeholder pending confirmation
    // that this org's actual Named Credential for that class is literally
    // named "MOVEit_Server" (very likely, since the example class references
    // it directly, but the example wasn't confirmed to be the SAME Named
    // Credential record used elsewhere) — verify in Setup before relying on
    // it.
    private static final String MOVEIT_NAMED_CREDENTIAL = 'callout:MOVEit_Server';

    // UNRESOLVED — real folderId, source path, and dest path for OUR
    // channels; see class header, constraint 2. The reference example's own
    // values belong to a different, unrelated integration and must NOT be
    // reused literally.
    private static final String MOVEIT_FOLDER_ID = 'UNCONFIRMED_FOLDER_ID';
    private static final String MOVEIT_SOURCE_PATH = 'UNCONFIRMED_SOURCE_PATH';
    private static final String MOVEIT_DEST_PATH = 'UNCONFIRMED_DEST_PATH';

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
            HttpRequest req = buildMoveitUploadRequest(result.fileName, fileBody,
                    delimiter == ',' ? 'text/csv' : 'text/plain');

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
     * Builds the confirmed MOVEit upload request shape (see class header,
     * fourth correction): POST multipart/form-data with source/dest/file
     * parts to /api/v1/folders/{folderId}/files via the MOVEit_Server Named
     * Credential.
     *
     * Deliberately builds the ENTIRE multipart body as one String, then
     * converts to a Blob exactly once — this sidesteps the base64-
     * concatenation bug found in the reference example (see class header):
     * that approach base64-encoded the header text, file bytes, and footer
     * text SEPARATELY and concatenated the encoded strings, which does not
     * reconstruct the original bytes correctly unless every piece before
     * the last has a byte length that's an exact multiple of 3. Building one
     * String first is safe here because every channel's file content is
     * plain text (CSV/semicolon-delimited) — never true binary. A channel
     * that ever needed real binary content would need different handling,
     * not this shortcut.
     */
    @TestVisible
    private HttpRequest buildMoveitUploadRequest(String fileName, String fileBody, String contentType) {
        String boundary = '----MOVEitBoundary' + Datetime.now().getTime();

        String body = '--' + boundary + '\r\n'
                + 'Content-Disposition: form-data; name="source"\r\n\r\n' + MOVEIT_SOURCE_PATH + '\r\n'
                + '--' + boundary + '\r\n'
                + 'Content-Disposition: form-data; name="dest"\r\n\r\n' + MOVEIT_DEST_PATH + '\r\n'
                + '--' + boundary + '\r\n'
                + 'Content-Disposition: form-data; name="file"; filename="' + fileName + '"\r\n'
                + 'Content-Type: ' + contentType + '\r\n\r\n'
                + fileBody + '\r\n'
                + '--' + boundary + '--\r\n';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(MOVEIT_NAMED_CREDENTIAL + '/api/v1/folders/' + MOVEIT_FOLDER_ID + '/files');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'multipart/form-data; boundary=' + boundary);
        req.setBodyAsBlob(Blob.valueOf(body));
        req.setTimeout(120000);
        return req;
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
