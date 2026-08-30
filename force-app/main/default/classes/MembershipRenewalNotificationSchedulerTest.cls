/**
 * Design scaffold — not compiled/tested production code.
 */
@isTest
private class MembershipRenewalNotificationSchedulerTest {

    @isTest
    static void testExecute_enqueuesBatchJob() {
        // MembershipRenewalNotificationScheduler.execute() should hand off
        // to Database.executeBatch with a bounded scope size (see class
        // header comment re: the 100-callout-per-transaction limit).
        Test.startTest();
        System.schedule('Test-MD022EX-Schedule', '0 0 2 * * ?',
                new MembershipRenewalNotificationScheduler('MD022EX'));
        Test.stopTest();

        // After stopTest(), any batch job enqueued by the scheduled Apex
        // would have run synchronously; asserting on CronTrigger confirms
        // the job was scheduled without error.
        List<CronTrigger> scheduled = [
            SELECT Id, CronJobDetail.Name FROM CronTrigger WHERE CronJobDetail.Name = 'Test-MD022EX-Schedule'
        ];
        System.assertEquals(1, scheduled.size(), 'The scheduled job should be registered exactly once');
    }
}
