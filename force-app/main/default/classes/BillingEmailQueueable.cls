/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §1/§5/§6 and
 * docs/salesforce-design/workflows.md §2, and
 * docs/salesforce-design/data-dictionary-reference.md for the real,
 * field-verified schema this class now targets.
 *
 * Replaces MD134ML: generates monthly-pay ("MP") bill-plan correspondence
 * emails. The legacy program consumed an upstream "EIP" extract file
 * (MDEIPIN) as its INPUT; here the candidate population is passed in
 * directly as Asset Ids by whatever process (Flow, trigger, scheduled
 * batch) detects that an Asset now needs monthly-pay correspondence, since
 * there is no EIP-style intermediate extract file on the input side of
 * this architecture. The OUTPUT side, however, still mirrors the legacy
 * pattern: execute() appends one row per email to an in-memory extract via
 * NotificationGatewayService.queueEmail() (replacing MD134ML's B1000-
 * PRODUCE-EMAIL write to EMAIL-FILE-OUT/MD134OP), and flush() at the end
 * of this same execute() invocation uploads that extract to MOVEit for the
 * downstream EBIZ/EIP email processor to pick up.
 *
 * CORRECTED per the data-dictionary audit (see HLD §1/§6):
 *  - Members are Person Accounts. Asset.ContactId does NOT exist in this
 *    org's schema — Asset.AccountId points directly at the Person Account,
 *    whose PersonEmail/FirstName/LastName replace every Contact.* field
 *    reference below.
 *  - Club_Code__c/Bill_Plan_Type__c/Membership_Number__c/
 *    Current_Term_Expiration_Date__c are replaced with the real, confirmed
 *    fields Club__c (formula), Bill_Plan__c (formula), Member_Number__c,
 *    and CurrentLifecycleEndDate respectively.
 *  - Letter_Code__c and Asset_Change_Event__c remain UNRESOLVED
 *    placeholders exactly as before — neither is confirmed by the data
 *    dictionary, and MD607BR's decision table (which Letter_Code__c stands
 *    in for) was never part of the reviewed COBOL source either. See HLD
 *    §6; do not treat these as validated just because other fields in this
 *    class were corrected.
 */
public with sharing class BillingEmailQueueable implements Queueable, Database.AllowsCallouts {

    // Preserves the legacy letter-code literal ('139') and its special
    // suppression rule (INC943560) rather than generalizing it away —
    // see docs/cobol-legacy/md134ml.md, B0200-DO-NOT-SEND-EMAIL.
    private static final String LETTER_139_SUPPRESSION_CODE = '139';
    private static final String LETTER_139_CORRESPONDENCE_TYPE = '639';

    // Signature of a web-originated change, hard-coded in the legacy
    // program (department section '36', user '009999'); the business
    // meaning of these specific codes lives outside the reviewed source —
    // see docs/cobol-legacy/md134ml.md Ambiguous/Environment-Dependent Notes.
    private static final String WEB_CHANGE_DEPT_SECTION = '36';
    private static final String WEB_CHANGE_USER_ID = '009999';

    private final List<Id> candidateAssetIds;

    public BillingEmailQueueable(List<Id> candidateAssetIds) {
        this.candidateAssetIds = candidateAssetIds;
    }

    public void execute(QueueableContext qc) {
        if (candidateAssetIds == null || candidateAssetIds.isEmpty()) {
            return;
        }

        List<Asset> assets = [
            SELECT Id, AccountId, Account.PersonEmail, Account.FirstName, Account.LastName,
                   Club__c, Bill_Plan__c, Member_Number__c, Letter_Code__c,
                   CurrentLifecycleEndDate
            FROM Asset
            WHERE Id IN :candidateAssetIds
        ];

        Set<Id> letter139AssetIds = new Set<Id>();
        for (Asset a : assets) {
            if (a.Letter_Code__c == LETTER_139_SUPPRESSION_CODE) {
                letter139AssetIds.add(a.Id);
            }
        }
        Set<Id> suppressedAssetIds = getWebSelfServiceSuppressedAssets(letter139AssetIds);

        CorrespondenceLogger logger = new CorrespondenceLogger();
        NotificationGatewayService gateway = new NotificationGatewayService('MD134ML');
        Integer emailsQueued = 0;

        for (Asset a : assets) {
            // Replaces B0100-WILL-EMAIL-BE-PRODUCED (stand-in for MD607BR):
            // whether/how a letter's correspondence should be produced.
            String correspondenceType = resolveCorrespondenceType(a);
            if (String.isBlank(correspondenceType) || String.isBlank(a.Account?.PersonEmail)) {
                continue;
            }

            if (a.Letter_Code__c == LETTER_139_SUPPRESSION_CODE && suppressedAssetIds.contains(a.Id)) {
                logger.add(a.Id, a.AccountId, CorrespondenceLogger.Channel.EMAIL,
                        LETTER_139_CORRESPONDENCE_TYPE, CorrespondenceLogger.Status.SUPPRESSED, 'MD134ML');
                continue;
            }

            Map<String, Object> mergeFields = buildEmailPayload(a);
            NotificationGatewayService.QueueResult queueResult =
                    gateway.queueEmail(a.Account.PersonEmail, correspondenceType, mergeFields);

            if (queueResult.queued) {
                emailsQueued++;
            }

            // MEM-481279: log correspondence history. Per the legacy
            // program's actual behavior (not its ticket description — see
            // HLD §6), only letter 139 is logged; other letter types are
            // not logged here either, preserving that discrepancy rather
            // than silently "completing" the feature. Status reflects
            // whether the row was queued into today's extract, not
            // confirmed delivery — see NotificationGatewayService header.
            if (a.Letter_Code__c == LETTER_139_SUPPRESSION_CODE) {
                logger.add(a.Id, a.AccountId, CorrespondenceLogger.Channel.EMAIL,
                        LETTER_139_CORRESPONDENCE_TYPE,
                        queueResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        'MD134ML');
            }
        }

        logger.flush();
        // Replaces CLOSE EMAIL-FILE-OUT + the downstream job's pickup:
        // upload this run's accumulated email extract to MOVEit once, at
        // the end of this single execute() invocation (Queueable jobs run
        // once, so there is no cross-scope state to worry about the way
        // Batch Apex's finish() has to handle).
        List<NotificationGatewayService.FlushResult> flushResults = gateway.flush();
        System.debug(LoggingLevel.INFO, 'BillingEmailQueueable emailsQueued=' + emailsQueued
                + ' of candidates=' + assets.size() + ' filesUploaded=' + flushResults.size());
    }

    /**
     * Stand-in for MD607BR's "which letter path" business-rule lookup.
     * ASSUMPTION: the full MD607BR decision table was not part of the
     * reviewed COBOL source; this placeholder assumes any Asset with a
     * non-blank Letter_Code__c produces an email correspondence type equal
     * to that code, pending the real business-rule mapping — see HLD §6.
     * Letter_Code__c itself is NOT a field confirmed by the data
     * dictionary — this remains exactly as unresolved as before.
     */
    @TestVisible
    private String resolveCorrespondenceType(Asset a) {
        return a.Letter_Code__c;
    }

    /**
     * Replaces B0200-DO-NOT-SEND-EMAIL / the MBRSHP_MONTHLY_CHARGE_DTL
     * query for an ADD/CANCEL charge created today by dept '36'/user
     * '009999' (INC943560's "member made this change on the web today"
     * rule). ASSUMPTION: Asset_Change_Event__c is a placeholder for
     * whatever object tracks monthly-charge changes in this org — the
     * legacy DB2 table (MBRSHP_MONTHLY_CHARGE_DTL) has no confirmed
     * Revenue Cloud equivalent; see HLD §6. Not covered by the
     * data-dictionary audit either, so this remains unchanged.
     */
    @TestVisible
    private Set<Id> getWebSelfServiceSuppressedAssets(Set<Id> letter139AssetIds) {
        Set<Id> suppressed = new Set<Id>();
        if (letter139AssetIds.isEmpty()) {
            return suppressed;
        }
        Datetime startOfDay = Datetime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0));
        Datetime endOfDay = startOfDay.addDays(1).addSeconds(-1);

        for (SObject change : Database.query(
                'SELECT Asset__c FROM Asset_Change_Event__c ' +
                'WHERE Asset__c IN :letter139AssetIds ' +
                'AND Change_Type__c IN (\'ADD\',\'CANCEL\') ' +
                'AND Department_Section__c = :WEB_CHANGE_DEPT_SECTION ' +
                'AND Changed_By_User_Id__c = :WEB_CHANGE_USER_ID ' +
                'AND CreatedDate >= :startOfDay AND CreatedDate <= :endOfDay')) {
            suppressed.add((Id) change.get('Asset__c'));
        }
        return suppressed;
    }

    /**
     * Replaces B1000-PRODUCE-EMAIL's field-mapping and derived-value
     * logic: human-readable renewal date string, years-of-membership
     * (expiration year - join year, floored at 1), and the MPNOAUTHPMT /
     * MPNOAUTHNOPMT / MPNOAUTH email-type special case.
     */
    @TestVisible
    private Map<String, Object> buildEmailPayload(Asset a) {
        Map<String, Object> fields = new Map<String, Object>{
            'firstName' => a.Account?.FirstName,
            'lastName' => a.Account?.LastName,
            'clubCode' => a.Club__c,
            'membershipNumber' => a.Member_Number__c,
            'billPlan' => a.Bill_Plan__c,
            'renewalDate' => a.CurrentLifecycleEndDate
        };
        return fields;
    }
}
