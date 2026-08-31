/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §5 and
 * docs/salesforce-design/workflows.md §1.
 *
 * Replaces the JCL scheduling that ran MD021EX/MD022EX/MD022ER/MD022EC/
 * MD022LP/md022cc as separate nightly jobs. One Schedulable instance is
 * configured per Renewal_Notification_Rule__mdt.DeveloperName (matching
 * one legacy program's cadence), rather than one Apex class per program.
 */
public with sharing class MembershipRenewalNotificationScheduler implements Schedulable {

    private final String ruleDeveloperName;

    public MembershipRenewalNotificationScheduler(String ruleDeveloperName) {
        this.ruleDeveloperName = ruleDeveloperName;
    }

    public void execute(SchedulableContext sc) {
        // Scope size is no longer bounded by a per-record callout limit —
        // notifications are queued in memory across the whole run and
        // uploaded to MOVEit as one file per channel in finish() (see
        // NotificationGatewayService header and HLD §4). 50 is kept as a
        // conservative default for heap/query-row usage per scope, not as
        // a callout-limit workaround.
        Database.executeBatch(new MembershipRenewalNotificationBatch(ruleDeveloperName), 50);
    }

    /**
     * Convenience entry point for scheduling all active rules at once
     * (e.g. from an org-init script or Setup > Scheduled Jobs), rather
     * than requiring one CRON entry per legacy program by hand.
     */
    public static void scheduleAllActiveRules(String cronExpression) {
        for (Renewal_Notification_Rule__mdt rule : RenewalEligibilityRules.getActiveRules()) {
            String jobName = 'MembershipRenewalNotification-' + rule.Source_Program__c;
            System.schedule(jobName, cronExpression,
                    new MembershipRenewalNotificationScheduler(rule.Source_Program__c));
        }
    }
}
