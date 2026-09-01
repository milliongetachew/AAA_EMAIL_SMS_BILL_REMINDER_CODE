/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: start()/execute() query the custom objects Eft_Cau_Reject__c
 * (net-new proposal, not covered by the data-dictionary audit) and Asset,
 * whose real, confirmed fields (Club__c, Bill_Plan__c, Member_Number__c,
 * CurrentLifecycleEndDate) this scaffold now targets — see
 * high-level-design.md §1/§2/§6. These tests exercise the @TestVisible pure
 * helper methods that encode MD058CB's date-math and out-of-territory
 * branching, which do not require those objects to exist.
 *
 * CORRECTED per data-dictionary-reference.md: out-of-territory is now
 * Account.Out_Of_Territory__c (real, confirmed boolean field) — the former
 * guessed lodge-code equivalent is removed entirely, not just relabeled.
 */
@isTest
private class EftReconciliationBatchTest {

    @isTest
    static void testIsOutOfTerritory_readsAccountField() {
        // Replaces the former guessed lodge-code equivalent (docs/
        // cobol-legacy/md058cb.md's OUTOF-TERRITORY level-88 condition)
        // with the real Account.Out_Of_Territory__c field — see class
        // header on EftReconciliationBatch and HLD §1/§2/§6.
        EftReconciliationBatch batchInstance = new EftReconciliationBatch();

        Account outOfTerritoryAccount = new Account();
        outOfTerritoryAccount.put('Out_Of_Territory__c', true);
        Account inTerritoryAccount = new Account();
        inTerritoryAccount.put('Out_Of_Territory__c', false);

        Test.startTest();
        Boolean outOfTerritory = batchInstance.isOutOfTerritory(outOfTerritoryAccount);
        Boolean inTerritory = batchInstance.isOutOfTerritory(inTerritoryAccount);
        Boolean nullAccount = batchInstance.isOutOfTerritory(null);
        Test.stopTest();

        System.assertEquals(true, outOfTerritory);
        System.assertEquals(false, inTerritory);
        System.assertEquals(false, nullAccount);
    }

    @isTest
    static void testDaysToExpiration_suppressionThreshold() {
        // Replicates 8250-CHECK-NBR-DAYS-EXPIRE (UT020DT, MEM-481325):
        // days remaining to expiration, used to gate DO-NOT-PRINT at <= 23.
        EftReconciliationBatch batchInstance = new EftReconciliationBatch();
        Date processingDate = Date.newInstance(2026, 8, 30);

        Test.startTest();
        Integer daysAt20 = batchInstance.daysToExpiration(processingDate.addDays(20), processingDate);
        Integer daysAt30 = batchInstance.daysToExpiration(processingDate.addDays(30), processingDate);
        Test.stopTest();

        System.assertEquals(20, daysAt20);
        System.assert(daysAt20 <= 23, 'A membership expiring in 20 days should fall within the print-suppression window');
        System.assert(daysAt30 > 23, 'A membership expiring in 30 days should be outside the print-suppression window');
    }
}
