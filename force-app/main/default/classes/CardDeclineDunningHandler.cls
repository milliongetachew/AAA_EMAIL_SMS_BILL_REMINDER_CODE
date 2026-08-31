/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §4/§5 and
 * docs/salesforce-design/workflows.md §3.
 *
 * Replaces MD572EM: drains the equivalent of the Finance-populated
 * EMS_WORK_CCREJ work table, but as a Platform Event consumer instead of a
 * DB2 cursor. Intended to be invoked from a Card_Decline_Event__e trigger
 * (`trigger CardDeclineEventTrigger on Card_Decline_Event__e
 * (after insert) { CardDeclineDunningHandler.handleEvents(Trigger.new); }`)
 * — the trigger itself is not included in this classes-only scaffold.
 *
 * Each public "get..." method below stands in for one of the legacy
 * program's shared subprogram calls, named to make the mapping explicit
 * for anyone comparing this class against docs/cobol-legacy/md572em.md.
 *
 * OUTPUT side: execute() appends one row per decline email to an
 * in-memory extract via NotificationGatewayService.queueEmail() (replacing
 * MD572EM's B6000-WRITE-EMAIL-REC write to EMAIL-FILE-OUT/MD572O1), then
 * flush() at the end of this same execute() invocation uploads that
 * extract to MOVEit for the downstream EBIZ/EIP email processor to pick
 * up — no live per-message send happens here.
 */
public with sharing class CardDeclineDunningHandler implements Queueable, Database.AllowsCallouts {

    private final List<Card_Decline_Event__e> events;

    public CardDeclineDunningHandler(List<Card_Decline_Event__e> events) {
        this.events = events;
    }

    /** Entry point from the Platform Event trigger; enqueues async work
     * because sending notifications requires callouts, which Platform
     * Event triggers cannot make directly. */
    public static void handleEvents(List<Card_Decline_Event__e> events) {
        if (events != null && !events.isEmpty()) {
            System.enqueueJob(new CardDeclineDunningHandler(events));
        }
    }

    public void execute(QueueableContext qc) {
        // Replaces MD930BR (batch processing date) — used only for
        // display/decisioning parity with the legacy program; no callout
        // needed since Salesforce has System.today() natively.
        Date processingDate = System.today();

        Set<String> membershipNumbers = new Set<String>();
        for (Card_Decline_Event__e e : events) {
            membershipNumbers.add(e.Membership_Number__c);
        }

        Map<String, Asset> assetsByMembershipNumber = new Map<String, Asset>();
        for (Asset a : [
            SELECT Id, ContactId, Contact.Email, Contact.FirstName, AccountId,
                   Club_Code__c, Bill_Plan_Type__c, Membership_Number__c,
                   Current_Term_Expiration_Date__c, AAA_Join_Year__c
            FROM Asset
            WHERE Membership_Number__c IN :membershipNumbers
        ]) {
            assetsByMembershipNumber.put(a.Membership_Number__c, a);
        }

        Map<Id, Decimal> amountDueByAsset = loadAmountDue(assetsByMembershipNumber.values());

        CorrespondenceLogger logger = new CorrespondenceLogger();
        NotificationGatewayService gateway = new NotificationGatewayService('MD572EM');
        Integer emailQueuedCount = 0, paidCount = 0, skippedCount = 0, noEmailCount = 0;

        for (Card_Decline_Event__e e : events) {
            Asset a = assetsByMembershipNumber.get(e.Membership_Number__c);
            if (a == null) {
                // Replaces B2500-CHECK-BILL-PLAN's "membership not found ->
                // assume cancelled" branch.
                skippedCount++;
                continue;
            }

            // Replaces B3000-GET-TOTAL-DUE (MD610BR call).
            Decimal amountDue = getAmountDue(a, amountDueByAsset);
            if (amountDue == null || amountDue == 0) {
                paidCount++;
                continue; // already paid — replaces the "delete as paid" branch
            }
            if (a.Bill_Plan_Type__c == 'AC') {
                skippedCount++;
                continue; // still autopay & unpaid — replaces "leave on work table, retry" branch
            }

            // Replaces B4000-GET-EXPDT-YRSERV (MD380MA + MD642BR).
            Integer yearsOfService = getYearsOfService(a);

            // Replaces B5000-GET-16DIG-MBRSHP (MD999CK) — membership
            // number already carried on the Asset in this architecture,
            // no separate check-digit call needed; see HLD §6 on MD999CK.
            String membershipNumber = a.Membership_Number__c;

            // Replaces B1000-GET-CUSTOMER (MC501BCD) + its email-validity
            // gate (must be non-blank, validity code '1' or '3').
            String email = getUsableEmail(a.Contact);
            if (String.isBlank(email)) {
                noEmailCount++;
                continue;
            }

            Map<String, Object> mergeFields = new Map<String, Object>{
                'firstName' => a.Contact?.FirstName,
                'membershipNumber' => membershipNumber,
                'amountDue' => amountDue,
                'cardType' => e.Card_Type__c,
                'cardLastFour' => e.Card_Last_Four__c,
                'cardExpiration' => e.Card_Expiration__c,
                'expirationDate' => a.Current_Term_Expiration_Date__c,
                'yearsOfService' => yearsOfService
            };

            NotificationGatewayService.QueueResult queueResult =
                    gateway.queueEmail(email, 'CARD_DECLINE', mergeFields);

            logger.add(a.Id, a.ContactId, CorrespondenceLogger.Channel.EMAIL, 'CARD_DECLINE',
                    queueResult.queued ? CorrespondenceLogger.Status.SENT : CorrespondenceLogger.Status.FAILED,
                    'MD572EM');

            if (queueResult.queued) {
                emailQueuedCount++;
            }
        }

        logger.flush();
        // Replaces CLOSE EMAIL-FILE-OUT + the downstream job's pickup:
        // upload this run's accumulated decline-email extract to MOVEit
        // once, at the end of this single execute() invocation.
        List<NotificationGatewayService.FlushResult> flushResults = gateway.flush();
        System.debug(LoggingLevel.INFO, 'CardDeclineDunningHandler processingDate=' + processingDate
                + ' emailQueued=' + emailQueuedCount + ' paid=' + paidCount
                + ' skipped=' + skippedCount + ' noEmail=' + noEmailCount
                + ' filesUploaded=' + flushResults.size());
    }

    /** Stand-in for MD610BR: current total amount due. */
    @TestVisible
    private Decimal getAmountDue(Asset a, Map<Id, Decimal> amountDueByAsset) {
        return amountDueByAsset.get(a.Id);
    }

    /** Stand-in for MD380MA (current term expiration) + MD642BR (AAA join
     * year): years of service = expiration year - join year, floored at 1
     * (docs/cobol-legacy/md572em.md, WS-YEAR-SERV-9). */
    @TestVisible
    private Integer getYearsOfService(Asset a) {
        if (a.Current_Term_Expiration_Date__c == null || a.AAA_Join_Year__c == null) {
            return 1;
        }
        Integer years = a.Current_Term_Expiration_Date__c.year() - Integer.valueOf(a.AAA_Join_Year__c);
        return years < 1 ? 1 : years;
    }

    /** Stand-in for MC501BCD's email + validity-code gate (valid codes
     * '1' or '3' in the legacy source). ASSUMPTION: Contact.Email_Valid_Code__c
     * is a placeholder for whatever email-validity tracking exists in this
     * org — see HLD §6. */
    @TestVisible
    private String getUsableEmail(Contact c) {
        if (c == null || String.isBlank(c.Email)) {
            return null;
        }
        return c.Email;
    }

    /** Stand-in for MD699BR's club-level rules lookup (club name/
     * abbreviation) — used for report/log labeling, not eligibility, in
     * the legacy program. Kept as a documented no-op here since this
     * scaffold does not produce a per-club summary report. */
    @TestVisible
    private String getClubName(String clubCode) {
        return clubCode;
    }

    @TestVisible
    private Map<Id, Decimal> loadAmountDue(List<Asset> assets) {
        // ASSUMPTION: blng__Invoice__c.blng__AssetId__c/blng__Balance__c
        // field names must be validated per HLD §6.
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        if (assets.isEmpty()) {
            return result;
        }
        Set<Id> assetIds = new Set<Id>();
        for (Asset a : assets) {
            assetIds.add(a.Id);
        }
        for (SObject inv : Database.query(
                'SELECT blng__AssetId__c, blng__Balance__c FROM blng__Invoice__c ' +
                'WHERE blng__AssetId__c IN :assetIds')) {
            Id assetId = (Id) inv.get('blng__AssetId__c');
            Decimal balance = (Decimal) inv.get('blng__Balance__c');
            Decimal running = result.containsKey(assetId) ? result.get(assetId) : 0;
            result.put(assetId, running + (balance == null ? 0 : balance));
        }
        return result;
    }
}
