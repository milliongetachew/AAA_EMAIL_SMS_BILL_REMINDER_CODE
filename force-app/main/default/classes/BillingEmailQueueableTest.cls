/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: BillingEmailQueueable queries Asset custom fields
 * (Letter_Code__c, Club_Code__c, Bill_Plan_Type__c, Membership_Number__c)
 * and the placeholder object Asset_Change_Event__c, none of which are
 * deployed metadata yet — see high-level-design.md §2/§6. These tests
 * exercise the class's @TestVisible helper methods directly (which do not
 * require those objects) plus a smoke test of the full execute() path.
 */
@isTest
private class BillingEmailQueueableTest {

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"messageId":"MOCK-139"}');
            return res;
        }
    }

    @isTest
    static void testResolveCorrespondenceType_returnsLetterCode() {
        // Stand-in for MD607BR (B0100-WILL-EMAIL-BE-PRODUCED) — see class
        // header comment on resolveCorrespondenceType's placeholder logic.
        Asset a = new Asset();
        a.put('Letter_Code__c', '139');
        BillingEmailQueueable queueable = new BillingEmailQueueable(new List<Id>());

        Test.startTest();
        String correspondenceType = queueable.resolveCorrespondenceType(a);
        Test.stopTest();

        System.assertEquals('139', correspondenceType);
    }

    @isTest
    static void testBuildEmailPayload_mapsCoreFields() {
        Account acc = new Account(Name = 'Test Household');
        insert acc;
        Contact con = new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane@example.com', AccountId = acc.Id);
        insert con;

        Asset a = new Asset(ContactId = con.Id, AccountId = acc.Id);
        a.put('Club_Code__c', '001');
        a.put('Bill_Plan_Type__c', 'MP');
        a.put('Membership_Number__c', '1234567890123456');

        BillingEmailQueueable queueable = new BillingEmailQueueable(new List<Id>());

        Test.startTest();
        Map<String, Object> payload = queueable.buildEmailPayload(a);
        Test.stopTest();

        System.assertEquals('001', payload.get('clubCode'));
        System.assertEquals('MP', payload.get('billPlan'));
        System.assertEquals('1234567890123456', payload.get('membershipNumber'));
    }

    @isTest
    static void testGetWebSelfServiceSuppressedAssets_emptyInputReturnsEmptySet() {
        // Empty input should short-circuit before querying
        // Asset_Change_Event__c (the INC943560 web-origination check),
        // matching B0200-DO-NOT-SEND-EMAIL's guard for non-letter-139 rows.
        BillingEmailQueueable queueable = new BillingEmailQueueable(new List<Id>());

        Test.startTest();
        Set<Id> suppressed = queueable.getWebSelfServiceSuppressedAssets(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, suppressed.size());
    }
}
