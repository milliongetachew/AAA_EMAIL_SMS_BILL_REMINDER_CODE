/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: execute() queries Asset by custom field Membership_Number__c and
 * blng__Invoice__c, none of which are deployed metadata yet — see
 * high-level-design.md §2/§6. These tests focus on the @TestVisible
 * helper methods that encapsulate the legacy subroutine-equivalent logic
 * (MD610BR/MD380MA/MD642BR/MC501BCD stand-ins), which do not require
 * those objects to exist.
 */
@isTest
private class CardDeclineDunningHandlerTest {

    @isTest
    static void testGetYearsOfService_flooredAtOne() {
        // Replicates WS-YEAR-SERV-9 = expiration year - AAA join year,
        // floored at 1 (docs/cobol-legacy/md572em.md).
        Asset recentJoin = new Asset();
        recentJoin.put('Current_Term_Expiration_Date__c', Date.newInstance(2026, 12, 31));
        recentJoin.put('AAA_Join_Year__c', 2026);

        Asset longTenure = new Asset();
        longTenure.put('Current_Term_Expiration_Date__c', Date.newInstance(2026, 12, 31));
        longTenure.put('AAA_Join_Year__c', 2010);

        CardDeclineDunningHandler handler = new CardDeclineDunningHandler(new List<Card_Decline_Event__e>());

        Test.startTest();
        Integer flooredYears = handler.getYearsOfService(recentJoin);
        Integer longYears = handler.getYearsOfService(longTenure);
        Test.stopTest();

        System.assertEquals(1, flooredYears, 'Same-year join should floor to 1 year of service, not 0');
        System.assertEquals(16, longYears);
    }

    @isTest
    static void testGetUsableEmail_blankEmailReturnsNull() {
        Contact noEmail = new Contact(FirstName = 'Jane', LastName = 'Doe');
        Contact withEmail = new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane@example.com');

        CardDeclineDunningHandler handler = new CardDeclineDunningHandler(new List<Card_Decline_Event__e>());

        Test.startTest();
        String blank = handler.getUsableEmail(noEmail);
        String usable = handler.getUsableEmail(withEmail);
        Test.stopTest();

        System.assertEquals(null, blank,
                'No usable email must be treated as a skip, matching MD572EM B1000-GET-CUSTOMER\'s email-validity gate');
        System.assertEquals('jane@example.com', usable);
    }

    @isTest
    static void testGetAmountDue_readsFromPreloadedMap() {
        Asset a = new Asset();
        Id fakeAssetId = a.Id; // null for an unsaved Asset, used only as a map key here
        Map<Id, Decimal> amountDueByAsset = new Map<Id, Decimal>{ fakeAssetId => 42.50 };

        CardDeclineDunningHandler handler = new CardDeclineDunningHandler(new List<Card_Decline_Event__e>());

        Test.startTest();
        Decimal amountDue = handler.getAmountDue(a, amountDueByAsset);
        Test.stopTest();

        System.assertEquals(42.50, amountDue, 'Replaces MD610BR — bulk-preloaded map avoids one callout/query per row');
    }
}
