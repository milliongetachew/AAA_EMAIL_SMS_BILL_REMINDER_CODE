/**
 * Design scaffold — not compiled/tested production code.
 * NOTE: start()/execute() query the custom objects Eft_Cau_Reject__c and
 * Asset custom fields, which are not deployed metadata yet — see
 * high-level-design.md §2/§6. These tests exercise the @TestVisible pure
 * helper methods that encode MD058CB's date-math and lodge-type branching,
 * which do not require those objects to exist.
 */
@isTest
private class EftReconciliationBatchTest {

    @isTest
    static void testIsOutOfTerritory_matchesLegacyLodgeCodes() {
        // Replicates the OUTOF-TERRITORY level-88 condition (lodge codes
        // '1','3','4','6') from docs/cobol-legacy/md058cb.md.
        EftReconciliationBatch batchInstance = new EftReconciliationBatch();

        Test.startTest();
        Boolean outOfTerritory = batchInstance.isOutOfTerritory('3');
        Boolean inTerritory = batchInstance.isOutOfTerritory('2');
        Boolean nullCode = batchInstance.isOutOfTerritory(null);
        Test.stopTest();

        System.assertEquals(true, outOfTerritory);
        System.assertEquals(false, inTerritory);
        System.assertEquals(false, nullCode);
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
