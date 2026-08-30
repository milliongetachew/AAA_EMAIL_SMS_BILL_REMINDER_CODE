/**
 * Design scaffold — not compiled/tested production code.
 * See docs/salesforce-design/high-level-design.md §4 for the integration
 * architecture this class implements.
 *
 * Thin wrapper around a single External Service / Named Credential
 * ("Notification_Gateway") that stands in for every downstream file
 * consumer in the legacy pipeline: the SMS gateway, the mobile push
 * service, and the EBIZ/EIP email processor. Every MD021EX/MD022*/MD134ML/
 * MD572EM/MD058CB output file write is replaced by a call into this class.
 *
 * GOVERNOR LIMIT NOTE: a single Apex transaction allows at most 100
 * callouts. Batch Apex classes that call this service from execute() MUST
 * either (a) size their batch scope so per-record callouts stay under 100,
 * or (b) use a bulk send API on the notification provider (one callout per
 * scope carrying many recipients) once that API is confirmed available.
 * Do not raise batch scope size without addressing this.
 */
public with sharing class NotificationGatewayService {

    public class NotificationResult {
        public Boolean success;
        public String providerMessageId;
        public String errorMessage;
    }

    private static final String NAMED_CREDENTIAL = 'callout:Notification_Gateway';

    /**
     * Replaces the SMS output-file writes in MD021EX (2020-WRITE-OUTFILE),
     * MD022EX/MD022ER (2020-WRITE-OUTFILE / W0000-WRITE-OUTFILE), MD022EC/
     * MD022LP/md022cc (4000-WRITE-SMS-RECORD), and MD058CB
     * (1930/1940 SMS record build).
     */
    public NotificationResult sendSms(String toPhoneE164, String templateCode,
            Map<String, Object> mergeFields) {
        Map<String, Object> payload = new Map<String, Object>{
            'channel' => 'SMS',
            'to' => toPhoneE164,
            'templateCode' => templateCode,
            'mergeFields' => mergeFields
        };
        return doCallout('/v1/messages/sms', payload);
    }

    /**
     * Replaces the Push output-file writes in MD022ER (W1000-WRITE-PUSH-FILE),
     * MD022LP/md022cc/MD022ZA (5000-WRITE-PUSH-RECORD /
     * 6000-WRITE-PUSH-RECORD), and MD058CB (1910/1920 Push record build).
     */
    public NotificationResult sendPush(String subscriberKey, String templateCode,
            Map<String, Object> mergeFields) {
        Map<String, Object> payload = new Map<String, Object>{
            'channel' => 'PUSH',
            'subscriberKey' => subscriberKey,
            'templateCode' => templateCode,
            'mergeFields' => mergeFields
        };
        return doCallout('/v1/messages/push', payload);
    }

    /**
     * Replaces the email output-file writes in MD134ML
     * (B1000-PRODUCE-EMAIL), MD572EM (B6000-WRITE-EMAIL-REC), and MD058CB
     * (1950/1960 Email record build).
     */
    public NotificationResult sendEmail(String toAddress, String templateCode,
            Map<String, Object> mergeFields) {
        Map<String, Object> payload = new Map<String, Object>{
            'channel' => 'EMAIL',
            'to' => toAddress,
            'templateCode' => templateCode,
            'mergeFields' => mergeFields
        };
        return doCallout('/v1/messages/email', payload);
    }

    @TestVisible
    private NotificationResult doCallout(String path, Map<String, Object> payload) {
        NotificationResult result = new NotificationResult();
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(NAMED_CREDENTIAL + path);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(JSON.serialize(payload));
            req.setTimeout(30000);

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                result.success = true;
                result.providerMessageId = (String) body.get('messageId');
            } else {
                result.success = false;
                result.errorMessage = 'HTTP ' + res.getStatusCode() + ': ' + res.getBody();
            }
        } catch (Exception ex) {
            result.success = false;
            result.errorMessage = ex.getMessage();
        }
        return result;
    }
}
