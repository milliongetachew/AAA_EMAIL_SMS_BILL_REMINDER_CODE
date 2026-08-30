/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md for object/field assumptions.
 *
 * Replaces MD300MA (the correspondence-history update subroutine) and,
 * functionally, the EMS_WORK_CAU / EMS_WORK_LETTER queue tables that the
 * legacy programs used as their own record of "what was queued/sent to
 * whom." See MEM-481279 (MD134ML) and MEM-481283 (MD058CB) for the two
 * legacy change tickets that introduced MD300MA calls.
 *
 * Callers MUST use the buffer pattern below (add() then flush()) rather
 * than inserting one Correspondence__c row per record processed, to avoid
 * DML-in-a-loop inside Batch Apex execute() methods.
 */
public with sharing class CorrespondenceLogger {

    public enum Channel { SMS, PUSH, EMAIL, LETTER }
    public enum Status { SENT, FAILED, SUPPRESSED, SKIPPED }

    public class Entry {
        public Id relatedAssetId;
        public Id relatedContactId;
        public Channel channel;
        public String correspondenceTypeCode;
        public Status status;
        public String sourceProgram;
        public String errorMessage;

        public Entry(Id relatedAssetId, Id relatedContactId, Channel channel,
                String correspondenceTypeCode, Status status, String sourceProgram) {
            this.relatedAssetId = relatedAssetId;
            this.relatedContactId = relatedContactId;
            this.channel = channel;
            this.correspondenceTypeCode = correspondenceTypeCode;
            this.status = status;
            this.sourceProgram = sourceProgram;
        }
    }

    private List<Entry> buffer = new List<Entry>();

    /** Queues an entry for the next flush() — mirrors deferring the
     * MD300MA call so multiple sends in one batch scope become one DML. */
    public void add(Entry entry) {
        buffer.add(entry);
    }

    public void add(Id relatedAssetId, Id relatedContactId, Channel channel,
            String correspondenceTypeCode, Status status, String sourceProgram) {
        add(new Entry(relatedAssetId, relatedContactId, channel, correspondenceTypeCode,
                status, sourceProgram));
    }

    /**
     * Bulk-inserts all buffered entries as Correspondence__c records.
     * ASSUMPTION: Correspondence__c is a new custom object (not yet created
     * in the org) with fields Related_Asset__c, Related_Contact__c,
     * Channel__c, Correspondence_Type_Code__c, Status__c, Sent_Date__c,
     * Source_Program__c, Error_Message__c — see high-level-design.md §2/§3.
     */
    public List<Database.SaveResult> flush() {
        if (buffer.isEmpty()) {
            return new List<Database.SaveResult>();
        }

        List<SObject> toInsert = new List<SObject>();
        for (Entry e : buffer) {
            SObject corr = Schema.getGlobalDescribe().get('Correspondence__c').newSObject();
            corr.put('Related_Asset__c', e.relatedAssetId);
            corr.put('Related_Contact__c', e.relatedContactId);
            corr.put('Channel__c', e.channel.name());
            corr.put('Correspondence_Type_Code__c', e.correspondenceTypeCode);
            corr.put('Status__c', e.status.name());
            corr.put('Sent_Date__c', Datetime.now());
            corr.put('Source_Program__c', e.sourceProgram);
            corr.put('Error_Message__c', e.errorMessage);
            toInsert.add(corr);
        }

        buffer.clear();

        // allOrNone=false mirrors the legacy tolerance for "member
        // cancelled"/"member missing" (SQLCODE 100) as non-fatal, logged
        // conditions rather than aborting the whole run (see MD134ML's
        // B4000-UPDATE-CORR-HIST and MD058CB's 1970-UPDATE-CORR-HIST).
        return Database.insert(toInsert, false);
    }

    public Integer pendingCount() {
        return buffer.size();
    }
}
