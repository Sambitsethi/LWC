/**
 * @description       : Apex Controller to search for authorization based on SA UUID or Subscription ID.
 * Apex Class Name    :  SMD_SearchAuthorizationController
 * Version            :  2.0
 * Modification Log   :
 * --------------------------------------------------------------------------------------------------
 * When                Story            Who                 What
 * --------------------------------------------------------------------------------------------------
 * 01/08/2026          SMD2-203         SS1U               Created
 * 07/30/2026          SMD2-20954       SS1U               Added searchAuthorizationwithEncryption method to search by encrypted subscription ID
 * 07/31/2026                           SS1U               removed cacheable = true from Auraenabled methods
 * 09/17/2026          SMD2-XXXXX       SS1U               Replaced internal Subscriptions__x/ServiceAgreements__x/AuthAccounts__x
 *                                                          lookups with EAPI callouts (subscriptions/{id} and
 *                                                          subscriptions/srv-agreements/{uuid}).
 *                                                          searchAuthorization now takes clientId as an explicit parameter
 *                                                          (supplied by Smd_VendorSearchAuthorizationCmp via the new
 *                                                          getClientId() method) - this is the ONLY entry point that changed.
 *                                                          searchAuthorizationwithEncryption (used by
 *                                                          Smd_VendorAuthorizationDetailsCmp) keeps its original signature
 *                                                          and still resolves clientId internally - no change to that
 *                                                          component's call site or behavior.
 *                                                          TODO: confirm the success JSON shape for the srv-agreements/{uuid}
 *                                                          endpoint against a live 200 response - assumed identical to the
 *                                                          subscriptions/{id} shape (subscriptionDetails[]) per the shared
 *                                                          Postman capture, but that capture only showed the 404 body for uuid.
 *                                                          TODO: confirm actual Named Credential API name in org (assumed
 *                                                          'SMD_vendorCreateUpdate' per the sample callout snippet provided).
 **************************************************************************************************/
public with sharing class SMD_SearchAuthorizationController {
    public Static Boolean throwException = false;

    private static final String NAMED_CREDENTIAL = 'callout:SMD_vendorCreateUpdate'; // TODO confirm NC name
    private static final String API_SUBSCRIPTIONS_PATH = '/api/subscriptions'; // confirmed via Postman/dev console capture - NOT part of the named credential's base URL
    private static final String STATUS_PENDING = 'PG';
    private static final String STATUS_CANCELED = 'CD';


    /**
     * @description This method searches for authorization based on SA UUID or Subscription ID.
     *              Used by Smd_VendorSearchAuthorizationCmp. clientId is supplied by the caller -
     *              call getClientId() first and pass its result in here.
     * @method searchAuthorization
     * @param String saUuid - Service Agreement UUID to search by
     * @param String subscriptionId - Subscription ID to search by
     * @param String clientId - Client id to scope the EAPI callout to, resolved by the caller via getClientId()
     * @return SearchAuthResponse - Response object containing search results
     */
    @AuraEnabled
    public static SearchAuthResponse searchAuthorization(String saUuid, String subscriptionId, String clientId) {
        return performSearch(saUuid, subscriptionId, clientId);
    }

    /**
     * @description This method searches for authorization Subscription ID with encryption.
     *              Used by Smd_VendorAuthorizationDetailsCmp - signature and behavior unchanged;
     *              clientId is still resolved internally here, exactly as before.
     * @method searchAuthorizationwithEncryption
     * @param String subscriptionId - Subscription ID to search by
     * @return SearchAuthResponse - Response object containing search results
     */
    @AuraEnabled
    public static SearchAuthResponse searchAuthorizationwithEncryption(String subscriptionId){// SMD2-20954 - Added method to search by encrypted subscription ID
        return performSearch(null, SMD_CryptoServiceLwc.decryptText(subscriptionId), getRunningUserClientId());
    }

    /**
     * @description Resolves the client id (SMD_Third_Party_Id__c) for the running portal user's account
     *              (User -> Contact -> Account -> SMD_Third_Party_Id__c), for callers that don't already
     *              have it. Smd_VendorSearchAuthorizationCmp should call this once and pass the result
     *              into searchAuthorization.
     * @method getClientId
     * @return String - the resolved client id, or null if the running user has none
     */
    @AuraEnabled(cacheable=true)
    public static String getClientId() {
        return getRunningUserClientId();
    }

    /**
     * @description Shared search implementation for both entry points above.
     * @method performSearch
     * @param String saUuid - Service Agreement UUID to search by
     * @param String subscriptionId - Subscription ID to search by
     * @param String clientId - Client id to scope the EAPI callout to
     * @return SearchAuthResponse - Response object containing search results
     */
    private static SearchAuthResponse performSearch(String saUuid, String subscriptionId, String clientId) {
        SearchAuthResponse response = new SearchAuthResponse(false, null, null);
        Map<String, Object> labelMap = getLabelMap();
        try {
            if (throwException) {
                throw new AuraHandledException('This is a test exception');
            }

            if (String.isBlank(clientId)) {
                response.errorMessage = (String) labelMap.get('invalidSearchRequest');
                return response;
            }

            // ================= SEARCH BY SUBSCRIPTION ID =================
            if (String.isNotBlank(subscriptionId)) {
                return searchBySubscriptionId(subscriptionId, clientId, labelMap);
            }

            // ================= SEARCH BY SA UUID =================
            if (String.isNotBlank(saUuid)) {
                return searchBySaUuid(saUuid, clientId, labelMap);
            }
            // ================= NO INPUT =================
            response.errorMessage = (String) labelMap.get('invalidSearchRequest');
            return response;
        } catch (Exception ex) {
            SMD_Logger.logError('performSearch', 'SMD_SearchAuthorizationController', ex.getTypeName(), ex);
            response.errorMessage = 'Unable to process request';
            return response;
        }
    }


    /**
     * @description This method searches for authorization by subscription ID via EAPI callout
     * @method searchBySubscriptionId
     * @param String subscriptionId - The subscription ID to search for
     * @param String clientId - The running user's resolved client id, passed to the EAPI
     * @param Map<String, Object> labelMap - Map of labels for error messages
     * @return SearchAuthResponse - Response object containing search results
     */
    private static SearchAuthResponse searchBySubscriptionId(String subscriptionId, String clientId, Map<String, Object> labelMap) {
        SearchAuthResponse response = new SearchAuthResponse(false, null, null);

        String endpoint = NAMED_CREDENTIAL + API_SUBSCRIPTIONS_PATH + '/' + EncodingUtil.urlEncode(subscriptionId, 'UTF-8')
            + '?includeAccounts=true&clientId=' + EncodingUtil.urlEncode(clientId, 'UTF-8');

        CalloutOutcome outcome = doCallout(endpoint);
        if (!outcome.success) {
            response.errorMessage = mapCalloutError(outcome, labelMap, 'subscriptionIdNotFound');
            return response;
        }

        List<SubscriptionWrapper> subscriptions = getFilteredSubscriptions(outcome.parsedResponse.subscriptionDetails, clientId);
        if (subscriptions.isEmpty()) {
            response.errorMessage = (String) labelMap.get('subscriptionIdNotFound');
            return response;
        }
        if (subscriptions[0].authStatus == STATUS_CANCELED) {
            response.errorMessage = (String) labelMap.get('subscriptonIdCanceled');
            return response;
        }

        response.success = true;
        response.subscriptions = subscriptions;
        return response;
    }

    /**
     * @description This method searches for authorization by SA UUID via EAPI callout.
     *              Unlike subscription-id search, a single SA UUID can resolve to multiple subscriptions.
     * @method searchBySaUuid
     * @param String saUuid - Service Agreement UUID to search by
     * @param String clientId - The running user's resolved client id, passed to the EAPI
     * @param Map<String, Object> labelMap - Map of labels for error messages
     * @return SearchAuthResponse - Response object containing search results
     */
    private static SearchAuthResponse searchBySaUuid(String saUuid, String clientId, Map<String, Object> labelMap) {
        SearchAuthResponse response = new SearchAuthResponse(false, null, null);

        String endpoint = NAMED_CREDENTIAL + API_SUBSCRIPTIONS_PATH + '/srv-agreements/' + EncodingUtil.urlEncode(saUuid, 'UTF-8')
            + '?includeAccounts=true&clientId=' + EncodingUtil.urlEncode(clientId, 'UTF-8');

        CalloutOutcome outcome = doCallout(endpoint);
        if (!outcome.success) {
            response.errorMessage = mapCalloutError(outcome, labelMap, 'saUuidNotFound');
            return response;
        }

        List<SubscriptionWrapper> subscriptions = getFilteredSubscriptions(outcome.parsedResponse.subscriptionDetails, clientId);
        if (subscriptions.isEmpty()) {
            response.errorMessage = (String) labelMap.get('saUuidNotFound');
            return response;
        }

        response.success = true;
        response.subscriptions = subscriptions;
        return response;
    }

    /**
     * @description Executes the GET callout and parses either the success or error body.
     * @method doCallout
     * @param String endpoint - Fully-qualified 'callout:' endpoint including query string
     * @return CalloutOutcome - wraps either a parsed success response or the parsed error body
     */
    private static CalloutOutcome doCallout(String endpoint) {
        CalloutOutcome outcome = new CalloutOutcome();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('correlationId', UUID.randomUUID().toString());

        Http http = new Http();
        HttpResponse res = http.send(request);
        outcome.statusCode = res.getStatusCode();

        if (outcome.statusCode == 200) {
            outcome.success = true;
            outcome.parsedResponse = (ApiSubscriptionSearchResponse) JSON.deserialize(res.getBody(), ApiSubscriptionSearchResponse.class);
        } else {
            outcome.success = false;
            try {
                outcome.parsedError = (ApiErrorResponse) JSON.deserialize(res.getBody(), ApiErrorResponse.class);
            } catch (Exception parseEx) {
                // Body didn't match the expected error shape; fall through with statusCode only.
            }
        }
        return outcome;
    }

    /**
     * @description Maps a failed callout to one of the existing user-facing labels. 404/DATA:NOT_FOUND
     *              maps to the not-found label for the search type; anything else is a generic failure.
     * @method mapCalloutError
     */
    private static String mapCalloutError(CalloutOutcome outcome, Map<String, Object> labelMap, String notFoundLabelKey) {
        if (outcome.statusCode == 404) {
            return (String) labelMap.get(notFoundLabelKey);
        }
        SMD_Logger.logError('doCallout', 'SMD_SearchAuthorizationController', 'CalloutFailure',
            new AuraHandledException('EAPI callout failed with status ' + outcome.statusCode));
        return 'Unable to process request';
    }

    /**
     * @description Resolves the client id (SMD_Third_Party_Id__c) for the running portal user's account,
     *              the same relationship Smd_VendorAuthorizationDetailsCmp walks via GraphQL
     *              (User -> Contact -> Account -> SMD_Third_Party_Id__c).
     * @method getRunningUserClientId
     * @return String - the resolved client id, or null if the running user has none
     */
    private static String getRunningUserClientId() {
        // TODO: route this through SMD_AccountSelector / a User selector if your architecture
        // standard requires all SOQL to live in a Selector class - left inline here since no
        // existing selector method for this join was visible in the shared files.
        List<User> users = [
            SELECT Contact.Account.SMD_Third_Party_Id__c
            FROM User
            WHERE Id = :UserInfo.getUserId()
            LIMIT 1
        ];
        if (users.isEmpty() || users[0].Contact == null || users[0].Contact.Account == null) {
            return null;
        }
        return users[0].Contact.Account.SMD_Third_Party_Id__c;
    }

    /**
     * @description This method retrieves Third Party IDs from Accounts using SMD_AccountSelector.
     *              Used only for enriching callout results with companyName/historicalMonths/registrationType -
     *              no longer used to filter/authorize results, since the EAPI already scopes by clientId.
     * @method getThirdPartyIds
     * @return Map<String, Account> - Map of third party IDs to Account records
     */
    private static Map<String, Account> getThirdPartyIds() {
        Map<String, Account> thirdPartyIds = new Map<String, Account>();
        for (Account acc : SMD_AccountSelector.getAccountswithThirdPartyId()) {
            if (String.isNotBlank(acc.SMD_Third_Party_Id__c)) {
                thirdPartyIds.put(acc.SMD_Third_Party_Id__c, acc);
            }
        }
        return thirdPartyIds;
    }

    /**
     * @description This method retrieves label map from JSON deserialization
     * @method getLabelMap
     * @return Map<String, Object> - Map of labels for error messages
     */
    private static Map<String, Object> getLabelMap() {
        return (Map<String, Object>) JSON.deserializeUntyped(
            Label.SMD_VendorSearchAuthorizationCmp_label
            );
    }

    /**
     * @description Converts API subscription details into the existing SubscriptionWrapper shape,
     *              excluding pending (PG) records - same rule the old getFilteredSubscriptions applied.
     * @method getFilteredSubscriptions
     * @param List<ApiSubscriptionDetail> apiDetails - subscription records returned by the EAPI
     * @param String clientId - client id used for the callout, used to key the Account enrichment lookup
     * @return List<SubscriptionWrapper> - Filtered list of subscription wrappers
     */
    private static List<SubscriptionWrapper> getFilteredSubscriptions(List<ApiSubscriptionDetail> apiDetails, String clientId) {
        List<SubscriptionWrapper> filtered = new List<SubscriptionWrapper>();
        if (apiDetails == null) {
            return filtered;
        }

        Map<String, Account> thirdPartyIds = getThirdPartyIds();

        for (ApiSubscriptionDetail detail : apiDetails) {
            if (detail.authStatusCd == STATUS_PENDING) {
                continue;
            }
            Account acc = thirdPartyIds.get(detail.clientId != null ? detail.clientId : clientId);

            SubscriptionWrapper wrapper = new SubscriptionWrapper();
            wrapper.subscriptionId = detail.subscriptionId;
            wrapper.encryptedSubscriptionId = SMD_CryptoServiceLwc.encryptText(detail.subscriptionId);
            wrapper.companyName = acc?.Name;
            wrapper.historicalMonths = acc?.SMD_How_historical_data_is_requested__c;
            wrapper.registrationType = acc?.SMD_Registration_Type__c;
            wrapper.subscriptionStartDate = detail.authStartDt;
            wrapper.subscriptionEndDate = detail.authEndDt;
            wrapper.authStatus = detail.authStatusCd;
            wrapper.clientId = detail.clientId;
            wrapper.subscriptionEmail = detail.customerEmail;
            filtered.add(wrapper);
        }
        return filtered;
    }

    // ===================== EAPI RESPONSE DESERIALIZATION =====================

    /**
     * @description Wrapper for the callout outcome - either a parsed success body or a parsed error body.
     */
    private class CalloutOutcome {
        Boolean success = false;
        Integer statusCode;
        ApiSubscriptionSearchResponse parsedResponse;
        ApiErrorResponse parsedError;
    }

    /**
     * @description Shape of a 200 response from both /api/subscriptions/{id} and
     *              /api/subscriptions/srv-agreements/{uuid} - confirmed identical for both endpoints
     *              (subscription-id search returns one element, uuid search can return several).
     */
    private class ApiSubscriptionSearchResponse {
        List<ApiSubscriptionDetail> subscriptionDetails;
    }

    private class ApiSubscriptionDetail {
        String subscriptionId;
        String clientId;
        String authMethodCd;
        String authStatusCd;
        String authStartDt;
        String authEndDt;
        List<String> scopeList;
        Integer resourceOwnerId;
        String customerEmail;
        String createdBy;
        String updatedBy;
        List<ApiAuthAccountDetail> authAccountDetails; // present on some responses (e.g. subscription-id search); absent on others (e.g. uuid search samples seen so far) - keep nullable
    }

    private class ApiAuthAccountDetail {
        String acctId;
        String acctUuid;
        String acctName;
        String isAuthorized;
        String createdBy;
        String updatedBy;
        List<ApiAuthServiceAgreementDetail> authSADetails;
    }

    private class ApiAuthServiceAgreementDetail {
        String saUuid;
        String saId;
        String isAuthorized;
        String commodity;
        String startDate;
        String endDate;
        String createdBy;
        String lastUpdatedBy;
    }

    /**
     * @description Shape of the 404 error body, e.g.:
     *              { "severity": "error", "errorType": "Technical", "timestamp": "...",
     *                "errors": [ { "code": 404, "reason": "DATA:NOT_FOUND", "message": "..." } ] }
     */
    private class ApiErrorResponse {
        String severity;
        String errorType;
        String timestamp;
        List<ApiErrorDetail> errors;
    }

    private class ApiErrorDetail {
        Integer code;
        String reason;
        String message;
    }

    // ===================== RESPONSE WRAPPER (unchanged - consumed as-is by the LWC) =====================

    /**
     * @description Wrapper class for search authorization response
     * @class SearchAuthResponse
     */
    public class SubscriptionWrapper{
        /**
         * @description Subscription ID
         * @field subscriptionId
         * @type String
         */
        @AuraEnabled public String subscriptionId;
        /**
         * @description encrypted Subscription ID
         * @field encryptedSubscriptionId
         * @type String
         */
        @AuraEnabled public String encryptedSubscriptionId;
        /**
         * @description Company Name
         * @field companyName
         * @type String
         */
        @AuraEnabled public String  companyName;
        /**
         * @description Historical Months
         * @field historicalMonths
         * @type String
         */
        @AuraEnabled public String historicalMonths;
        /**
         * @description Registration Type
         * @field registrationType
         * @type String
         */
        @AuraEnabled public String  registrationType;
        /**
         * @description Subscription Start Date
         * @field subscriptionStartDate
         * @type String
         */
        @AuraEnabled public String subscriptionStartDate;
        /**
         * @description Subscription End Date
         * @field subscriptionEndDate
         * @type String
         */
        @AuraEnabled public String subscriptionEndDate;
        /**
         * @description Authorization Status
         * @field authStatus
         * @type String
         */
        @AuraEnabled public String authStatus;

        /**
         * @description Client ID
         * @field clientId
         * @type String
         */
        @AuraEnabled public String clientId;
        /**
         * @description Subscription Email
         * @field subscriptionEmail
         * @type String
         */
        @AuraEnabled public String subscriptionEmail;
    }

    /**
     * @description Wrapper class for search authorization response
     * @class SearchAuthResponse
     */
    public class SearchAuthResponse {
        /**
         * @description Indicates if the search was successful
         * @field success
         * @type Boolean
         */
        @AuraEnabled public Boolean success;

        /**
         * @description Error message if the search failed
         * @field errorMessage
         * @type String
         */
        @AuraEnabled public String errorMessage;

        /**
         * @description List of subscriptions returned from the search
         * @field subscriptions
         * @type List<SubscriptionWrapper>
         */
        @AuraEnabled public List<SubscriptionWrapper> subscriptions;

        /**
         * @description Constructor for SearchAuthResponse
         * @method SearchAuthResponse
         * @param Boolean success - Indicates if the search was successful
         * @param String errorMessage - Error message if the search failed
         * @param List<SubscriptionWrapper> subscriptions - List of subscriptions returned from the search
         */
        public SearchAuthResponse(Boolean success, String errorMessage, List<SubscriptionWrapper> subscriptions) {
            this.success = success;
            this.errorMessage = errorMessage;
            this.subscriptions = subscriptions;
        }
    }
}
