/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §1/§2/§6 for the
 * "two signals, deliberately used together" correspondence design
 * decision this class implements, and
 * docs/salesforce-design/data-dictionary-reference.md for the real,
 * field-verified schema.
 *
 * Replaces MD300MA (the correspondence-history update subroutine) and,
 * functionally, the EMS_WORK_CAU / EMS_WORK_LETTER queue tables that the
 * legacy programs used as their own record of "what was queued/sent to
 * whom." See MEM-481279 (MD134ML) and MEM-481283 (MD058CB) for the two
 * legacy change tickets that introduced MD300MA calls.
 *
 * CORRECTED per the data-dictionary audit: flush() now writes to BOTH of
 * two complementary signals, not one invented object:
 *  (1) `Correspondence_Log__c` — a NEW custom object (deliberately NOT
 *      named `Correspondence__c`, to avoid colliding with the field below)
 *      giving full timestamped audit history: who, what channel, what
 *      code, when, success/failure. This does not exist in the org yet
 *      and would need to be created via metadata.
 *  (2) `Asset.Correspondence__c` — an EXISTING 216-value multipicklist
 *      already used in this org for exactly this purpose. A multipicklist
 *      cannot represent "sent at time Y" or a code sent more than once, so
 *      this is a lightweight, at-a-glance signal only, not a replacement
 *      for (1). See HLD §6 for why both are recommended rather than
 *      picking one.
 *
 * Callers MUST use the buffer pattern below (add() then flush()) rather
 * than inserting/updating one record per record processed, to avoid
 * DML-in-a-loop inside Batch Apex execute() methods.
 */
public with sharing class CorrespondenceLogger {

    public enum Channel { SMS, PUSH, EMAIL, LETTER }
    public enum Status { SENT, FAILED, SUPPRESSED, SKIPPED }

    public class Entry {
        public Id relatedAssetId;
        public Id relatedAccountId;
        public Channel channel;
        public String correspondenceTypeCode;
        public Status status;
        public String sourceProgram;
        public String errorMessage;

        public Entry(Id relatedAssetId, Id relatedAccountId, Channel channel,
                String correspondenceTypeCode, Status status, String sourceProgram) {
            this.relatedAssetId = relatedAssetId;
            this.relatedAccountId = relatedAccountId;
            this.channel = channel;
            this.correspondenceTypeCode = correspondenceTypeCode;
            this.status = status;
            this.sourceProgram = sourceProgram;
        }
    }

    // Legacy correspondence codes are 3-digit numeric strings (e.g. '639',
    // '868', '768', '668', '168') matching the 216 values already defined
    // on Asset.Correspondence__c. Only codes shaped like that are eligible
    // for the multipicklist dual-write below — non-numeric template/source
    // codes (e.g. 'MD022EX', 'CARD_DECLINE') are logged to
    // Correspondence_Log__c only. ASSUMPTION: this shape check is a
    // placeholder for validating against the real 216-value picklist
    // definition, which a production implementation should query via
    // describe rather than pattern-match — see class header.
    private static final Pattern LEGACY_CODE_PATTERN = Pattern.compile('^[0-9]{3}$');

    private List<Entry> buffer = new List<Entry>();

    /** Queues an entry for the next flush() — mirrors deferring the
     * MD300MA call so multiple sends in one batch scope become one DML. */
    public void add(Entry entry) {
        buffer.add(entry);
    }

    public void add(Id relatedAssetId, Id relatedAccountId, Channel channel,
            String correspondenceTypeCode, Status status, String sourceProgram) {
        add(new Entry(relatedAssetId, relatedAccountId, channel, correspondenceTypeCode,
                status, sourceProgram));
    }

    /**
     * Bulk-writes all buffered entries to BOTH correspondence signals (see
     * class header): inserts full-detail rows into `Correspondence_Log__c`,
     * then bulk-updates `Asset.Correspondence__c` (existing multipicklist)
     * to add any newly-seen legacy-shaped codes, preserving values already
     * selected. Both operations are bulk (one SOQL + one DML each across
     * the whole buffer), never per-entry, to stay safe inside Batch Apex
     * execute().
     *
     * ASSUMPTION: `Correspondence_Log__c` is a new custom object (not yet
     * created in the org) with fields Related_Asset__c, Related_Account__c
     * (Person Account lookup — named Related_Account__c, not
     * Related_Contact__c, since the member is an Account here), Channel__c,
     * Correspondence_Type_Code__c, Status__c, Sent_Date__c,
     * Source_Program__c, Error_Message__c — see high-level-design.md §2/§3.
     */
    public List<Database.SaveResult> flush() {
        if (buffer.isEmpty()) {
            return new List<Database.SaveResult>();
        }

        List<SObject> toInsert = new List<SObject>();
        for (Entry e : buffer) {
            SObject corr = Schema.getGlobalDescribe().get('Correspondence_Log__c').newSObject();
            corr.put('Related_Asset__c', e.relatedAssetId);
            corr.put('Related_Account__c', e.relatedAccountId);
            corr.put('Channel__c', e.channel.name());
            corr.put('Correspondence_Type_Code__c', e.correspondenceTypeCode);
            corr.put('Status__c', e.status.name());
            corr.put('Sent_Date__c', Datetime.now());
            corr.put('Source_Program__c', e.sourceProgram);
            corr.put('Error_Message__c', e.errorMessage);
            toInsert.add(corr);
        }

        updateAssetCorrespondenceMultipicklist();

        buffer.clear();

        // allOrNone=false mirrors the legacy tolerance for "member
        // cancelled"/"member missing" (SQLCODE 100) as non-fatal, logged
        // conditions rather than aborting the whole run (see MD134ML's
        // B4000-UPDATE-CORR-HIST and MD058CB's 1970-UPDATE-CORR-HIST).
        return Database.insert(toInsert, false);
    }

    /**
     * Signal (2) from the class header: bulk-appends any newly-seen
     * legacy-shaped correspondence codes onto Asset.Correspondence__c,
     * preserving whatever codes are already selected. Never removes a
     * code, and never touches an Asset that has no eligible entries in
     * this flush.
     */
    @TestVisible
    private void updateAssetCorrespondenceMultipicklist() {
        Map<Id, Set<String>> newCodesByAssetId = new Map<Id, Set<String>>();
        for (Entry e : buffer) {
            if (e.relatedAssetId == null || !isLegacyShapedCode(e.correspondenceTypeCode)) {
                continue;
            }
            if (!newCodesByAssetId.containsKey(e.relatedAssetId)) {
                newCodesByAssetId.put(e.relatedAssetId, new Set<String>());
            }
            newCodesByAssetId.get(e.relatedAssetId).add(e.correspondenceTypeCode);
        }
        if (newCodesByAssetId.isEmpty()) {
            return;
        }

        Map<Id, Asset> assetsById = new Map<Id, Asset>(
                [SELECT Id, Correspondence__c FROM Asset WHERE Id IN :newCodesByAssetId.keySet()]);

        List<Asset> toUpdate = new List<Asset>();
        for (Id assetId : newCodesByAssetId.keySet()) {
            Asset a = assetsById.get(assetId);
            if (a == null) {
                continue;
            }
            Set<String> merged = new Set<String>();
            if (String.isNotBlank(a.Correspondence__c)) {
                merged.addAll(a.Correspondence__c.split(';'));
            }
            Integer sizeBefore = merged.size();
            merged.addAll(newCodesByAssetId.get(assetId));
            if (merged.size() == sizeBefore) {
                continue; // no new codes for this asset — skip the update
            }
            toUpdate.add(new Asset(Id = assetId, Correspondence__c = String.join(new List<String>(merged), ';')));
        }

        if (!toUpdate.isEmpty()) {
            // allOrNone=false: a bad/retired code should not block the
            // Correspondence_Log__c insert above, which is the
            // authoritative audit trail — this multipicklist write is a
            // best-effort supplementary signal.
            Database.update(toUpdate, false);
        }
    }

    @TestVisible
    private Boolean isLegacyShapedCode(String code) {
        return String.isNotBlank(code) && LEGACY_CODE_PATTERN.matcher(code).matches();
    }

    public Integer pendingCount() {
        return buffer.size();
    }
}
