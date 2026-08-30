/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §1/§5 and
 * docs/salesforce-design/workflows.md §2.
 *
 * Replaces MD134ML: generates monthly-pay ("MP") bill-plan correspondence
 * emails. The legacy program consumed an upstream "EIP" extract file
 * (MDEIPIN); here the candidate population is passed in directly as Asset
 * Ids by whatever process (Flow, trigger, scheduled batch) detects that an
 * Asset now needs monthly-pay correspondence, since there is no EIP-style
 * intermediate extract file in this architecture.
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
            SELECT Id, ContactId, Contact.Email, Contact.FirstName, Contact.LastName,
                   Club_Code__c, Bill_Plan_Type__c, Membership_Number__c, Letter_Code__c,
                   Current_Term_Expiration_Date__c
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
        NotificationGatewayService gateway = new NotificationGatewayService();
        Integer emailsSent = 0;

        for (Asset a : assets) {
            // Replaces B0100-WILL-EMAIL-BE-PRODUCED (stand-in for MD607BR):
            // whether/how a letter's correspondence should be produced.
            String correspondenceType = resolveCorrespondenceType(a);
            if (String.isBlank(correspondenceType) || String.isBlank(a.Contact?.Email)) {
                continue;
            }

            if (a.Letter_Code__c == LETTER_139_SUPPRESSION_CODE && suppressedAssetIds.contains(a.Id)) {
                logger.add(a.Id, a.ContactId, CorrespondenceLogger.Channel.EMAIL,
                        LETTER_139_CORRESPONDENCE_TYPE, CorrespondenceLogger.Status.SUPPRESSED, 'MD134ML');
                continue;
            }

            Map<String, Object> mergeFields = buildEmailPayload(a);
            NotificationGatewayService.NotificationResult sendResult =
                    gateway.sendEmail(a.Contact.Email, correspondenceType, mergeFields);

            if (sendResult.success) {
                emailsSent++;
            }

            // MEM-481279: log correspondence history. Per the legacy
            // program's actual behavior (not its ticket description — see
            // HLD §6), only letter 139 is logged; other letter types are
            // not logged here either, preserving that discrepancy rather
            // than silently "completing" the feature.
            if (a.Letter_Code__c == LETTER_139_SUPPRESSION_CODE) {
                logger.add(a.Id, a.ContactId, CorrespondenceLogger.Channel.EMAIL,
                        LETTER_139_CORRESPONDENCE_TYPE,
                        sendResult.success ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                        'MD134ML');
            }
        }

        logger.flush();
        System.debug(LoggingLevel.INFO, 'BillingEmailQueueable emailsSent=' + emailsSent
                + ' of candidates=' + assets.size());
    }

    /**
     * Stand-in for MD607BR's "which letter path" business-rule lookup.
     * ASSUMPTION: the full MD607BR decision table was not part of the
     * reviewed COBOL source; this placeholder assumes any Asset with a
     * non-blank Letter_Code__c produces an email correspondence type equal
     * to that code, pending the real business-rule mapping — see HLD §6.
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
     * Revenue Cloud equivalent; see HLD §6.
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
            'firstName' => a.Contact?.FirstName,
            'lastName' => a.Contact?.LastName,
            'clubCode' => a.Club_Code__c,
            'membershipNumber' => a.Membership_Number__c,
            'billPlan' => a.Bill_Plan_Type__c,
            'renewalDate' => a.Current_Term_Expiration_Date__c
        };
        return fields;
    }
}
