public with sharing class CRM_ApplicationController {
    public class ApplicationException extends Exception {
    }

    public static final String COUNTRY_USA = 'USA';
    // List of Service Areas external IDs that fall under the 'WA' service area
    // for Medicare Supplement applications
    public static final List<String> MEDICARE_SUPP_WA_SAS = new List<String>{
        'WA',
        'Clark Co',
        'Asuris'
    };

    /**
     * Explicitly used to refresh the User's session on Salesforce
     * Used only when the security timeout's get refreshed on LX App Entry
     */
    @AuraEnabled(cacheable=false)
    public static void refreshUserSession() {
        //By calling this method, we have refreshed the Session.
    }

    /**
     * Retrieves data that can't be optimally retrieved via uiRecordApi methods
     * in the Lightning Component. Return values include app-specific data like
     * Applicant_Info__c, Prior_Coverage__c, and OpportunityLineItem, in
     * addition to return values from getLookupData()
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getData(
        String applicationId,
        String serviceArea,
        String lob,
        Date effDate,
        Boolean isBridgeSpan,
        String zipCode,
        String county
    ) {
        // Get lookup/reference data
        Map<String, Object> response = getLookupData(
            serviceArea,
            lob,
            effDate,
            isBridgeSpan,
            zipCode,
            county
        );
        // Add in app-specific data
        response.put('applicants', getApplicants(applicationId));
        response.put('oppLineItems', getOppLineItems(applicationId));
        response.put(
            'enrollmentValidationErrors',
            getEnrollmentValidationErrors(applicationId)
        );
        return response;
    }

    /**
     * Retrieves data used as reference/lookup values in the application, but
     * not modified in app entry, e.g. Product2, PriceBookEntry,
     * Product_Class__c, Product_Filter__c, Zip_County_Network_Map__c, and
     * Medical_Neighborhoods__c
     */
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getLookupData(
        String serviceArea,
        String lob,
        Date effDate,
        Boolean isBridgeSpan,
        String zipCode,
        String county
    ) {
        // Retrieve all valid Product2 and child records
        List<ProductWrapper> products = getProducts(
            serviceArea,
            lob,
            effDate,
            isBridgeSpan
        );
        String state = getState(products);

        List<Map<String, String>> zipCounties;
        // For <65, retrieve Zip_County_Network_Map__c records and filter data
        // according to matching networks and/or product filters, retrieve an
        // array of valid zip/county pairs for the service area, then further
        // filter products according to the zip + county entered
        if (lob == GlobalConstants.IndividualLOB) {
            List<Zip_County_Network_Map__c> zcnms = getZipCountyNetworkMaps(
                serviceArea,
                lob,
                effDate
            );
            filterDataByServiceArea(zcnms, products);
            zipCounties = getZipCountiesUnder65(zcnms, serviceArea, effDate);
            filterProductsByZipCounty(products, zcnms, zipCode, county);
        } else {
            // For Medigap, just get the valid zip/county pairs based on
            // ZipCountyServiceAreaMap__c (don't need to filter products)
            zipCounties = getZipCountiesMedigap(serviceArea, effDate);
        }

        return new Map<String, Object>{
            'products' => getProductMaps(products),
            'zipCounties' => zipCounties,
            'medicalNeighborhoods' => getMedicalNeighborhoods(
                serviceArea,
                effDate
            ),
            'state' => state,
            'recordTypeIds' => getRecordTypeIds(serviceArea, lob)
        };
    }

    // Using a wrapper class allows more flexibility to filter and sort
    private class ProductWrapper implements Comparable {
        Product2 product;
        List<PricebookEntry> pricebookEntries;
        List<ProductClassWrapper> productClasses;
        private ProductWrapper(Product2 p, String lob) {
            this.product = p;
            this.pricebookEntries = p.PricebookEntries;
            productClasses = new List<ProductClassWrapper>();
            for (Product_Class__c pc : p.ProductClassIDs__r) {
                productClasses.add(new ProductClassWrapper(pc, lob));
            }
        }
        // Sort using a custom order
        public Integer compareTo(Object compareTo) {
            ProductWrapper other = (ProductWrapper) compareTo;
            List<String> nameOrder = new List<String>{
                'Direct Bronze',
                'Direct Silver',
                'Direct Gold',
                'Direct Platinum'
            };
            if (
                nameOrder.contains(this.product.Name) &&
                nameOrder.contains(other.product.Name)
            ) {
                Integer thisIndex = nameOrder.indexOf(this.product.Name);
                Integer otherIndex = nameOrder.indexOf(other.product.Name);
                if (thisIndex == otherIndex)
                    return 0;
                if (thisIndex > otherIndex)
                    return 1;
                return -1;
            }
            if (
                this.product.Name.toUpperCase() ==
                other.product.Name.toUpperCase()
            )
                return 0;
            if (
                this.product.Name.toUpperCase() >
                other.product.Name.toUpperCase()
            )
                return 1;
            return -1;
        }
        // Remove product classes that don't match network or product filter,
        // and sort according to the custom sort order for the LOB
        public void filterProductClasses(
            Set<String> productFilters,
            Set<String> networks
        ) {
            for (Integer i = this.productClasses.size() - 1; i >= 0; i--) {
                Product_Class__c pc = this.productClasses[i].productClass;
                if (
                    !productFilters.contains(pc.Product_Filter__c) &&
                    !networks.contains(pc.Network_Name__c)
                ) {
                    this.productClasses.remove(i);
                }
            }
        }

        // Get a Map that more closely resembles a queried SObject list to
        // return to the client side
        public Map<String, Object> getMap() {
            List<Product_Class__c> pcs = new List<Product_Class__c>();
            for (ProductClassWrapper pc : this.productClasses) {
                pcs.add(pc.productClass);
            }
            if (pcs.size() == 0) {
                return null;
            }
            return new Map<String, Object>{
                'Id' => this.product.Id,
                'Name' => this.product.Name,
                'Description' => this.product.Description,
                'Plan_Number__c' => this.product.Plan_Number__c,
                'PricebookEntries' => this.pricebookEntries,
                'ProductClassIDs__r' => pcs
            };
        }
    }

    private static List<Map<String, Object>> getProductMaps(
        List<ProductWrapper> products
    ) {
        List<Map<String, Object>> res = new List<Map<String, Object>>();
        products.sort();
        for (ProductWrapper p : products) {
            p.productClasses.sort();
            res.add(p.getMap());
        }
        return res;
    }

    private class ProductClassWrapper implements Comparable {
        Product_Class__c productClass;
        List<String> sortOrder;
        private ProductClassWrapper(Product_Class__c pc, String lob) {
            this.productClass = pc;
            if (lob == GlobalConstants.MedigapLOB) {
                this.sortOrder = new List<String>{
                    'Product__c',
                    'Description__c'
                };
            } else {
                this.sortOrder = new List<String>{
                    'Deductible_Amount__c',
                    'Product_Class_Value__c'
                };
            }
        }
        // Sorts on multiple fields based on a list of field API names
        public Integer compareTo(Object compareTo) {
            return CRM_ApplicationController.compareSobjects(
                this.productClass,
                ((ProductClassWrapper) compareTo).productClass,
                sortOrder
            );
        }
    }

    /**
     * Returns a list of products based on the service area and optionally
     * any Zip_County_Network_Map__c-based restrictions.  Additionally filters
     * the incoming list of Zip_County_Network_Map__c records based on the
     * available networks from the product query.
     */
    private static List<ProductWrapper> getProducts(
        String serviceArea,
        String lob,
        Date effDate,
        Boolean isBridgeSpan
    ) {
        String lobId = (isBridgeSpan ? 'Bridgespan' : null);
        Boolean acaProduct = true;
        if (lob == GlobalConstants.MedigapLOB) {
            acaProduct = false;
        }
        List<ProductWrapper> res = new List<ProductWrapper>();
        for (Product2 product : [
            SELECT
                Id,
                Name,
                Description,
                Plan_Number__c,
                (
                    SELECT Id, UnitPrice, Product2Id
                    FROM PricebookEntries
                    WHERE Pricebook2.IsStandard = TRUE
                    LIMIT 1
                ),
                (
                    SELECT
                        Id,
                        Name,
                        Description__c,
                        Active__c,
                        Deductible_Amount__c,
                        Product__c,
                        Product_Class_Value__c,
                        Product_Filter__c,
                        Not_Available_For_Under_Age_Subscriber__c,
                        Network_Name__c,
                        ExternalID__c,
                        Service_Area__c,
                        Service_Area__r.State__c,
                        Facets_Product_ID__c,
                        Class_Value_Facets_Product__c
                    FROM ProductClassIDs__r
                    WHERE
                        Service_Area__r.ExtAreaID__c = :serviceArea
                        AND Start_Date__c <= :effDate
                        AND (Closure_Date__c = NULL
                        OR Closure_Date__c > :effDate)
                        AND End_Date__c > :effDate
                        AND LOB_ID__c = :lobId
                )
            FROM Product2
            WHERE
                Legacy__c = FALSE
                AND Family = 'Individual'
                AND LOB__c = :lob
                AND ACA_Product__c = :acaProduct
                AND Id IN (
                    SELECT Product__c
                    FROM Product_Class__c
                    WHERE
                        Service_Area__r.ExtAreaID__c = :serviceArea
                        AND Start_Date__c <= :effDate
                        AND (Closure_Date__c = NULL
                        OR Closure_Date__c > :effDate)
                        AND End_Date__c > :effDate
                        AND LOB_ID__c = :lobId
                )
        ]) {
            res.add(new ProductWrapper(product, lob));
        }
        return res;
    }

    /**
        Filters Product2, Product_Class__c, and Zip_County_Network_Map__c data
        based on common product filter and network name values between those
        data sets
     */
    private static void filterDataByServiceArea(
        List<Zip_County_Network_Map__c> zcnms,
        List<ProductWrapper> products
    ) {
        Set<String> productFilters = new Set<String>();
        Set<String> networkNames = new Set<String>();
        for (ProductWrapper product : products) {
            for (ProductClassWrapper pc : product.productClasses) {
                if (pc.productClass.Product_Filter__c != null) {
                    productFilters.add(pc.productClass.Product_Filter__c);
                } else if (String.isNotBlank(pc.productClass.Network_Name__c)) {
                    networkNames.add(pc.productClass.Network_Name__c);
                }
            }
        }
        Set<String> zcnmProductFilters = new Set<String>();
        Set<String> zcnmNetworkNames = new Set<String>();
        for (Zip_County_Network_Map__c zcnm : zcnms) {
            if (zcnm.Product_Filter__c != null) {
                zcnmProductFilters.add(zcnm.Product_Filter__c);
            } else if (String.isNotBlank(zcnm.Restriction_Value__c)) {
                zcnmNetworkNames.add(zcnm.Restriction_Value__c);
            }
        }
        // Retain just the product filters / networks the Product_Class__c and
        // Zip_County_Network_Map__c records have in common
        productFilters.retainAll(zcnmProductFilters);
        networkNames.retainAll(zcnmNetworkNames);
        // Remove any Zip_County_Network_Map__c without a matching network or
        // product filter among the matching sets
        for (Integer i = zcnms.size() - 1; i >= 0; i--) {
            if (
                !networkNames.contains(zcnms[i].Restriction_Value__c) &&
                !productFilters.contains(zcnms[i].Product_Filter__c)
            ) {
                zcnms.remove(i);
            }
        }
        for (Integer i = products.size() - 1; i >= 0; i--) {
            products[i].filterProductClasses(productFilters, networkNames);
            if (products[i].productClasses.size() == 0) {
                products.remove(i);
            }
        }
    }

    private static void filterProductsByZipCounty(
        List<ProductWrapper> products,
        List<Zip_County_Network_Map__c> zcnms,
        String zipCode,
        String county
    ) {
        if (
            zipCode != null &&
            zipCode.trim().length() >= 5 &&
            String.isNotBlank(county)
        ) {
            Set<String> productFilters = new Set<String>();
            Set<String> networkNames = new Set<String>();
            for (Zip_County_Network_Map__c zcnm : zcnms) {
                if (
                    zcnm.Zip_Code__c == zipCode.trim().substring(0, 5) &&
                    zcnm.County__c == county.trim()
                ) {
                    if (zcnm.Product_Filter__c != null) {
                        productFilters.add(zcnm.Product_Filter__c);
                    } else if (String.isNotBlank(zcnm.Restriction_Value__c)) {
                        networkNames.add(zcnm.Restriction_Value__c);
                    }
                }
            }
            for (Integer i = products.size() - 1; i >= 0; i--) {
                products[i].filterProductClasses(productFilters, networkNames);
                if (products[i].productClasses.size() == 0) {
                    products.remove(i);
                }
            }
        } else {
            // If zip code & county aren't completely entered yet, return an
            // empty list of products
            products.clear();
        }
    }

    private static String getState(List<ProductWrapper> products) {
        if (
            products.size() > 0 &&
            products[0].productClasses.size() > 0 &&
            products[0].productClasses[0].productClass.Service_Area__r != null
        ) {
            return products[0]
                .productClasses[0]
                .productClass.Service_Area__r.State__c;
        }
        return null;
    }

    private static List<Zip_County_Network_Map__c> getZipCountyNetworkMaps(
        String serviceArea,
        String lob,
        Date effDate
    ) {
        if (lob == GlobalConstants.IndividualLOB) {
            return [
                SELECT
                    Id,
                    Zip_Code__c,
                    County__c,
                    Restriction_Value__c,
                    Product_Filter__c
                FROM Zip_County_Network_Map__c
                WHERE
                    ExtAreaID__c = :serviceArea
                    AND Restriction_Name__c = 'Network'
                    AND (Start_Date__c = NULL
                    OR Start_Date__c <= :effDate)
                    AND (End_Date__c = NULL
                    OR End_Date__c > :effDate)
                ORDER BY Zip_Code__c, County__c
            ];
        }
        return null;
    }

    @TestVisible
    private static List<Map<String, String>> getZipCountiesUnder65(
        List<Zip_County_Network_Map__c> zcnms,
        String serviceArea,
        Date effDate
    ) {
        Map<String, Map<String, String>> zcMap = new Map<String, Map<String, String>>();
        if (zcnms != null && zcnms.size() > 0) {
            // Get ZIP County Network maps and iterate
            for (Zip_County_Network_Map__c zcnm : zcnms) {
                String zcKey = zcnm.Zip_Code__c + zcnm.County__c;
                // Add the product IDs to the ZIP/county if it exists
                if (
                    // networkNames.contains(zcnm.Restriction_Value__c) &&
                    !zcMap.containsKey(zcKey)
                ) {
                    zcMap.put(
                        zcKey,
                        new Map<String, String>{
                            'zip' => zcnm.Zip_Code__c,
                            'county' => zcnm.County__c
                        }
                    );
                }
            }
        }
        return zcMap.values();
    }

    @TestVisible
    private static List<Map<String, String>> getZipCountiesMedigap(
        String serviceArea,
        Date effDate
    ) {
        List<Map<String, String>> res = new List<Map<String, String>>();
        for (ZipCountyServiceAreaMap__c zcsam : [
            SELECT Id, Service_Area__c, Zip_Code__c, County__c
            FROM ZipCountyServiceAreaMap__c
            WHERE
                ExtAreaID__c = :serviceArea
                AND LOB__c = :GlobalConstants.MedigapLOB
                AND Start_Date__c <= :effDate
                AND End_Date__c >= :effDate
            ORDER BY Zip_Code__c, County__c
        ]) {
            res.add(
                new Map<String, String>{
                    'zip' => zcsam.Zip_Code__c,
                    'county' => zcsam.County__c
                }
            );
        }
        return res;
    }

    private static List<Medical_Neighborhoods__c> getMedicalNeighborhoods(
        String serviceArea,
        Date effDate
    ) {
        List<Medical_Neighborhoods__c> medicalNeighborhoods = [
            SELECT
                Medical_Neighborhood_Name__c,
                Medical_Neighborhood_ID__c,
                County__c
            FROM Medical_Neighborhoods__c
            WHERE
                Service_Area__c = :serviceArea
                AND LOB__c = :GlobalConstants.LOB_LESS_THAN_65
                AND (Start_Date__c = NULL
                OR Start_Date__c <= :effDate)
                AND (End_Date__c = NULL
                OR End_Date__c > :effDate)
        ];
        return medicalNeighborhoods;
    }

    private static List<Applicant_Info__c> getApplicants(String applicationId) {
        List<Applicant_Info__c> applicants = new List<Applicant_Info__c>();
        if (!String.isBlank(applicationId)) {
            applicants = [
                SELECT
                    Id,
                    IsDeleted,
                    External_ID__c,
                    Application__c,
                    First_Name__c,
                    Last_Name__c,
                    Middle_Name__c,
                    Applicant__c,
                    Applicant_Account_ID__c,
                    SSN__c,
                    Sex__c,
                    Birth_Date__c,
                    Spoken_Language__c,
                    Use_of_Tobacco__c,
                    Primary_Applicant__c,
                    Applicant_Relationship__c,
                    Out_of_State__c,
                    Out_of_State_Reason__c,
                    Out_of_State_Reason_if_Other__c,
                    PCP_ID__c,
                    Federal_SEP_Reasons__c,
                    Plan_Specific_SEP_Reasons__c,
                    SEP_Other__c,
                    SEP_Reason_Event_Date__c,
                    Custody_Type__c,
                    Custody_Award_Date__c,
                    Custody_Coverage_Provided_By__c,
                    Self_Employed__c,
                    Self_Employed_Business__c,
                    Applicant_Signature_Date__c,
                    WSHIP_Personal_Rep_Relationship__c,
                    WSHIP_Personal_Representative_First_Name__c,
                    WSHIP_Personal_Representative_Last_Name__c,
                    MediGap_Exempt__c,
                    Medigap_Transfer_Grid__c,
                    Part_A_Hospital__c,
                    Part_B_Physician__c,
                    Medicare_HIC__c,
                    (
                        SELECT
                            Id,
                            IsDeleted,
                            Applicant_External_ID__c,
                            ACA_Type_of_Prior_Coverage__c,
                            ACA_Type_of_Prior_Coverage_Other__c,
                            Insurer_Name__c,
                            Policy_Number__c,
                            Coverage_From__c,
                            Coverage_To__c,
                            Type_of_Coverage__c, // Medigap only
                            Other_Coverage__c, // Medigap only
                            Benefit_Type__c
                        FROM Prior_Coverages__r
                    )
                FROM Applicant_Info__c
                WHERE Application__c = :applicationId AND IsDeleted = FALSE
            ];
        }

        if (String.isBlank(applicationId) || applicants.size() == 0) {
            applicants.add(
                new Applicant_Info__c(
                    Id = null,
                    External_ID__c = null,
                    First_Name__c = null,
                    Last_Name__c = null,
                    Middle_Name__c = null,
                    Application__c = null,
                    Applicant__c = null,
                    SSN__c = null,
                    Sex__c = null,
                    Birth_Date__c = null,
                    Spoken_Language__c = null,
                    Use_of_Tobacco__c = null,
                    Primary_Applicant__c = true,
                    Applicant_Relationship__c = GlobalConstants.Subscriber,
                    Out_of_State__c = null,
                    Out_of_State_Reason__c = null,
                    Out_of_State_Reason_if_Other__c = null,
                    PCP_ID__c = null,
                    Medical_Neighborhood__c = null,
                    Network__c = null,
                    Federal_SEP_Reasons__c = null,
                    Plan_Specific_SEP_Reasons__c = null,
                    SEP_Other__c = null,
                    SEP_Reason_Event_Date__c = null,
                    Custody_Type__c = null,
                    Custody_Award_Date__c = null,
                    Custody_Coverage_Provided_By__c = null,
                    Self_Employed__c = null,
                    Self_Employed_Business__c = null,
                    Part_A_Hospital__c = null,
                    Part_B_Physician__c = null,
                    Medicare_HIC__c = null
                )
            );
        }
        return applicants;
    }

    private static List<OpportunityLineItem> getOppLineItems(
        String applicationId
    ) {
        List<OpportunityLineItem> oppLineItems = new List<OpportunityLineItem>();
        if (!String.isBlank(applicationId)) {
            oppLineItems = [
                SELECT
                    Id,
                    OpportunityId,
                    Applied_For__c,
                    Quantity,
                    Product_Class__c,
                    Product_Class__r.Network_Name__c,
                    Description,
                    PricebookEntryId,
                    UnitPrice,
                    ServiceDate
                FROM OpportunityLineItem
                WHERE Opportunity.Application__c = :applicationId
            ];
        }
        if (String.isBlank(applicationId) || oppLineItems.size() == 0) {
            oppLineItems.add(
                new OpportunityLineItem(
                    Id = null,
                    OpportunityId = null,
                    Applied_For__c = true,
                    Quantity = 1,
                    Product_Class__c = null,
                    Description = null,
                    PricebookEntryId = null,
                    UnitPrice = null,
                    ServiceDate = Date.today()
                )
            );
        }
        return oppLineItems;
    }

    private static Map<String, Id> getRecordTypeIds(
        String serviceArea,
        String lob
    ) {
        String oppRecTypeId;
        String appRecTypeId;
        String applicantRecTypeId;
        if (lob == GlobalConstants.MedigapLOB) {
            appRecTypeId = GlobalConstants.ApplicationUnsubmittedRecordTypeId;
            applicantRecTypeId = GlobalConstants.ApplicantInfoUnsubmittedRecordTypeId;
            if (MEDICARE_SUPP_WA_SAS.contains(serviceArea)) {
                oppRecTypeId = GlobalConstants.individualNewWART;
            } else {
                oppRecTypeId = GlobalConstants.individualNewRT;
            }
        } else {
            appRecTypeId = GlobalConstants.ApplicationRecordTypeId;
            applicantRecTypeId = GlobalConstants.ApplicantInfoRecordTypeId;
            oppRecTypeId = GlobalConstants.individualNewACART;
        }
        return new Map<String, Id>{
            'Account' => GlobalConstants.individualRT,
            'Opportunity' => oppRecTypeId,
            'Application__c' => appRecTypeId,
            'Applicant_Info__c' => applicantRecTypeId
        };
    }

    @AuraEnabled
    public static Map<String, String> createCoreObjects(
        String serviceAreaExtId,
        String lob,
        Boolean isOnExchange
    ) {
        Map<String, String> response = new Map<String, String>();
        Map<String, Id> recordTypeIdMap = getRecordTypeIds(
            serviceAreaExtId,
            lob
        );
        Service_Area__c serviceAreaRef = new Service_Area__c(
            ExtAreaID__c = serviceAreaExtId
        );
        ApplicationTriggers.limitSoql = true;
        AccountTriggers.run = false;
        AccountServiceAreaUpdate.runOnce = false;
        // Create and insert subscriber person account
        Account acc = new Account(
            RecordTypeId = recordTypeIdMap.get('Account'),
            LastName = 'TEMP PERSON ACCOUNT',
            Service_Area__r = serviceAreaRef,
            IND_65_Applicant__c = (lob == GlobalConstants.IndividualLOB)
        );
        insert acc;
        AccountTriggers.run = true;
        AccountServiceAreaUpdate.runOnce = true;
        // Build up the opportunity

        Opportunity opp = new Opportunity(
            Name = 'TEMP OPPORTUNITY',
            RecordTypeId = recordTypeIdMap.get('Opportunity'),
            Type_of_Application__c = isOnExchange
                ? GlobalConstants.ApplicationTypeOnExchangeNew
                : GlobalConstants.ApplicationTypeNewEnrollment,
            LOB__c = lob,
            AccountId = acc.Id,
            StageName = GlobalConstants.STAGE_APP_RECEIVED,
            Service_Area__r = serviceAreaRef,
            CloseDate = Date.today().addDays(90),
            Created_Through_WA_Paper_App__c = true
        );
        // Insert the opportunity
        insert opp;
        // Retrieve IDs of records created via trigger on opportunity insert
        opp = [
            SELECT
                Id,
                Application__c,
                LOB__c,
                ACA_Paper_Application__c,
                Non_ACA_Paper_Application__c,
                AccountId,
                Account.PersonContactId,
                Service_Area__c,
                (SELECT Id FROM Applicants_Info__r)
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        // Update the application
        Application__c app = new Application__c(
            Id = opp.Application__c,
            RecordTypeId = recordTypeIdMap.get('Application__c'),
            Opportunity__c = opp.Id,
            Use_Lightning__c = true
        );
        ApplicationTriggers.limitSoql = false;
        update app;

        ApplicationTriggers.limitSoql = true;
        List<SObject> objectsToUpdate = new List<SObject>();
        if (opp.LOB__c == GlobalConstants.MedigapLOB) {
            WA_Paper_Application__c nonAcaApp = new WA_Paper_Application__c(
                Application__c = app.Id
            );
            insert nonAcaApp;
            app.WA_Paper_Application__c = nonAcaApp.Id;
            opp.Non_ACA_Paper_Application__c = nonAcaApp.Id;
            acc.WA_Paper_Application__c = nonAcaApp.Id;
        } else {
            ACA_Paper_Application__c acaApp = new ACA_Paper_Application__c(
                Application__c = app.Id
            );
            insert acaApp;
            app.ACA_Paper_Application__c = acaApp.Id;
            opp.ACA_Paper_Application__c = acaApp.Id;
            acc.ACA_Paper_Application__c = acaApp.Id;
        }
        objectsToUpdate.add(app);
        objectsToUpdate.add(opp);
        objectsToUpdate.add(acc);

        AccountTriggers.run = false;
        ApplicationTriggers.limitSoql = false;
        ApplicationTriggers.firstRun = true;
        ApplicationTriggers.run = true;
        update objectsToUpdate;
        AccountTriggers.run = true;
        response.putAll(
            new Map<String, String>{
                'personAccount' => acc.Id,
                'personContact' => opp.Account.PersonContactId,
                'opp' => opp.Id,
                'app' => app.Id,
                'acaApp' => app.ACA_Paper_Application__c,
                'nonAcaApp' => app.WA_Paper_Application__c,
                'serviceArea' => opp.Service_Area__c,
                'applicant' => opp.Applicants_Info__r[0].Id
            }
        );
        // Delete these records so they won't show up in Recent Items lists, reports, etc

        deleteRecords(new List<String>{ app.Id });
        return response;
    }

    @AuraEnabled
    public static Map<String, Object> saveApplication(
        Application__c app,
        Opportunity opp,
        List<OpportunityLineItem> oppLineItemsToUpsert,
        List<OpportunityLineItem> oppLineItemsToDelete,
        List<Applicant_Info__c> applicantsToUpsert,
        List<Applicant_Info__c> applicantsToDelete,
        List<Prior_Coverage__c> pcToUpsert,
        List<Prior_Coverage__c> pcToDelete,
        Opportunity_Comment__c opportunityNote,
        List<Enrollment_Validation_Error__c> enrValErrors,
        String serviceAreaExtId,
        String accountId,
        Boolean isNew
    ) {
        Map<String, Object> response = new Map<String, Object>();
        List<Map<String, Object>> timestamps = new List<Map<String, Object>>();
        //Handle save time log events
        List<Log_Event__e> logEvents = new List<Log_Event__e>();
        //Setup times for overall and specific
        Long fullStartTime, fullEndTime;
        Long startTime, timeElapsed;
        fullStartTime = Datetime.now().getTime();
        String logSaveType = isNew ? ' - New Record' : ' - Edit Record';

        timestamps.add(newTimestamp('Entering Apex saveApplication method'));
        if (isNew) {
            timestamps.add(newTimestamp('Undeleting temp records'));
            undeleteTempRecords(app.Id, opp.AccountId);
            timestamps.add(newTimestamp('Temp records undeleted'));
        }

        if (enrValErrors != null && enrValErrors.size() > 0) {
            timestamps.add(
                newTimestamp('Begin deleting Enrollment Validation Errors')
            );
            delete enrValErrors;
            timestamps.add(
                newTimestamp('Enrollment Validation Errors deleted')
            );
        }

        Map<String, Map<Account, Account>> returnedAccounts = new Map<String, Map<Account, Account>>();
        List<Account> personAccounts = new List<Account>();
        if (applicantsToUpsert != null && applicantsToUpsert.size() > 0) {
            returnedAccounts = buildPersonAccounts(
                app,
                accountId,
                applicantsToUpsert,
                isNew
            );
            personAccounts = new List<Account>(
                returnedAccounts.get('upsertAccounts').keyset()
            );
            ApplicationTriggers.limitSoql = true;
            AccountTriggers.run = false;
            AccountServiceAreaUpdate.runOnce = false;
            timestamps.add(newTimestamp('Begin upserting Person Account'));
            startTime = DateTime.now().getTime();
            upsert personAccounts;
            timeElapsed = Datetime.now().getTime() - startTime;
            timestamps.add(newTimestamp('Person Account upserted'));
            logEvents.add(
                PlatformEventHelper.createLogEvent(
                    'Info',
                    'Person Account Save' + logSaveType,
                    'CRM_ApplicationController',
                    'saveApplication',
                    personAccounts[0]?.Id,
                    'Apex',
                    String.valueOf(timeElapsed)
                )
            );
            AccountTriggers.run = true;
            AccountServiceAreaUpdate.runOnce = true;
        }

        if (opp != null) {
            if (
                personAccounts.size() > 0 &&
                (isNew || personAccounts[0].Id == opp.AccountId)
            ) {
                opp.Name =
                    personAccounts[0].FirstName +
                    ' ' +
                    personAccounts[0].LastName +
                    ' - ' +
                    opp.Type_of_Application__c +
                    ' - ' +
                    opp.LOB__c;
            }
            timestamps.add(newTimestamp('Begin updating Opportunity'));
            startTime = DateTime.now().getTime();
            update opp;
            timeElapsed = Datetime.now().getTime() - startTime;
            timestamps.add(newTimestamp('Opportunity updated'));
            logEvents.add(
                PlatformEventHelper.createLogEvent(
                    'Info',
                    'Opportunity Save' + logSaveType,
                    'CRM_ApplicationController',
                    'saveApplication',
                    opp.Id,
                    'Apex',
                    String.valueOf(timeElapsed)
                )
            );
        }

        // Retrieve details for inserted opportunity and related records after triggers have executed
        opp = getOpportunity(app.Opportunity__c);

        if (oppLineItemsToUpsert != null && oppLineItemsToUpsert.size() > 0) {
            oppLineItemsToUpsert = buildOppLineItems(oppLineItemsToUpsert, opp);
            timestamps.add(
                newTimestamp('Begin upserting Opportunity Line Item')
            );
            startTime = DateTime.now().getTime();
            upsert oppLineItemsToUpsert;
            timestamps.add(newTimestamp('Opportunity Line Item upserted'));
            timeElapsed = Datetime.now().getTime() - startTime;
            logEvents.add(
                PlatformEventHelper.createLogEvent(
                    'Info',
                    'Opportunity Line Item Save' + logSaveType,
                    'CRM_ApplicationController',
                    'saveApplication',
                    oppLineItemsToUpsert[0]?.Id,
                    'Apex',
                    String.valueOf(timeElapsed)
                )
            );
        }

        if (oppLineItemsToDelete != null && oppLineItemsToDelete.size() > 0) {
            timestamps.add(
                newTimestamp('Begin deleting Opportunity Line Item')
            );
            delete oppLineItemsToDelete;
            timestamps.add(newTimestamp('Opportunity Line Item deleted'));
        }

        //Used by Application and Applicant Infos
        Service_Area__c serviceAreaForQuestionnaire;
        Map<String, Id> recordTypeIdMap = getRecordTypeIds(
            opp.Service_Area__r.ExtAreaId__c,
            opp.LOB__c
        );
        app = buildApplication(app, opp, recordTypeIdMap.get('Application__c'));

        //Populate the Medical Questionnaire for Medigap applications
        if (opp.LOB__c == 'Medicare Supplement') {
            serviceAreaForQuestionnaire = [
                SELECT MediGap_Questionnaire__c
                FROM Service_Area__c
                WHERE Id = :opp.Service_Area__c
                LIMIT 1
            ];

            app.Medical_Questionnaire__c = serviceAreaForQuestionnaire.MediGap_Questionnaire__c;
        }
        timestamps.add(newTimestamp('Begin updating Application'));
        startTime = DateTime.now().getTime();
        ApplicationTriggers.limitSoql = false;
        update app;
        ApplicationTriggers.limitSoql = true;
        timestamps.add(newTimestamp('Application updated'));
        timeElapsed = Datetime.now().getTime() - startTime;
        response.put('recordId', app.Id);
        logEvents.add(
            PlatformEventHelper.createLogEvent(
                'Info',
                'Application update' + logSaveType,
                'CRM_ApplicationController',
                'saveApplication',
                app.Id,
                'Apex',
                String.valueOf(timeElapsed)
            )
        );

        // Delete Applicant_Info__c, Person Account, and Prior_Coverage__c records that have been removed, as needed
        if (
            !isNew &&
            ((applicantsToDelete != null && applicantsToDelete.size() > 0) ||
            (pcToDelete != null &&
            pcToDelete.size() > 0))
        ) {
            timestamps.add(
                newTimestamp(
                    'Begin deleting applicant, account, and/or prior coverage records'
                )
            );
            List<Id> applicantRecordsToDelete = getApplicantIdsToDelete(
                applicantsToDelete,
                pcToDelete
            );
            Database.delete(applicantRecordsToDelete, true);
            timestamps.add(
                newTimestamp(
                    'Applicant, account, and/or prior coverage records deleted'
                )
            );
        }

        if (applicantsToUpsert != null && applicantsToUpsert.size() > 0) {
            applicantsToUpsert = buildApplicants(
                applicantsToUpsert,
                opp.Applicants_Info__r,
                app.Id,
                opp.Id,
                personAccounts,
                recordTypeIdMap.get('Applicant_Info__c')
            );

            if (opp.LOB__c == 'Medicare Supplement') {
                for (Applicant_Info__c appInfo : applicantsToUpsert) {
                    appInfo.Medical_Questionnaire__c = serviceAreaForQuestionnaire.MediGap_Questionnaire__c;
                }
            }
            timestamps.add(newTimestamp('Begin upserting Applicants'));
            startTime = DateTime.now().getTime();
            upsert applicantsToUpsert;
            timestamps.add(newTimestamp('Applicants upserted'));
            timeElapsed = Datetime.now().getTime() - startTime;
            logEvents.add(
                PlatformEventHelper.createLogEvent(
                    'Info',
                    'Applicants upsert' + logSaveType,
                    'CRM_ApplicationController',
                    'saveApplication',
                    applicantsToUpsert[0]?.Id,
                    'Apex',
                    String.valueOf(timeElapsed)
                )
            );
        }

        if (pcToUpsert != null && pcToUpsert.size() > 0) {
            pcToUpsert = buildPriorCoverages(pcToUpsert);
            timestamps.add(newTimestamp('Begin upserting Prior Coverages'));
            startTime = DateTime.now().getTime();
            upsert pcToUpsert;
            timestamps.add(newTimestamp('Prior Coverages upserted'));
            timeElapsed = Datetime.now().getTime() - startTime;
            logEvents.add(
                PlatformEventHelper.createLogEvent(
                    'Info',
                    'Prior Coverage upsert' + logSaveType,
                    'CRM_ApplicationController',
                    'saveApplication',
                    pcToUpsert[0]?.Id,
                    'Apex',
                    String.valueOf(timeElapsed)
                )
            );
        }

        if (
            opportunityNote != null &&
            !String.isBlank(opportunityNote.Comment__c)
        ) {
            opportunityNote.Opportunity__c = opp.Id;
            timestamps.add(newTimestamp('Begin upserting Opportunity Note'));
            startTime = DateTime.now().getTime();
            upsert opportunityNote;
            timestamps.add(newTimestamp('Opportunity Note upserted'));
            timeElapsed = Datetime.now().getTime() - startTime;
            logEvents.add(
                PlatformEventHelper.createLogEvent(
                    'Info',
                    'Opportunity Note upsert' + logSaveType,
                    'CRM_ApplicationController',
                    'saveApplication',
                    opportunityNote.Id,
                    'Apex',
                    String.valueOf(timeElapsed)
                )
            );
        }

        Map<Account, Account> mergingAccounts = returnedAccounts.get(
            'mergeAccounts'
        );
        if (mergingAccounts != null) {
            for (Account masterAccount : mergingAccounts.keyset()) {
                Account mergingAccount = mergingAccounts.get(masterAccount);
                if (
                    masterAccount.Id != null &&
                    mergingAccount != null &&
                    mergingAccount.Id != null
                ) {
                    timestamps.add(newTimestamp('Begin merging Accounts'));
                    startTime = Datetime.now().getTime();
                    merge masterAccount mergingAccount;
                    timestamps.add(newTimestamp('Accounts merged'));
                    timeElapsed = Datetime.now().getTime() - startTime;
                    logEvents.add(
                        PlatformEventHelper.createLogEvent(
                            'Info',
                            'Account Merge' + logSaveType,
                            'CRM_ApplicationController',
                            'saveApplication',
                            masterAccount.Id,
                            'Apex',
                            String.valueOf(timeElapsed)
                        )
                    );
                }
            }
        }
        timestamps.add(newTimestamp('Returning response form Apex to LWC'));
        fullEndTime = Datetime.now().getTime();
        logEvents.add(
            PlatformEventHelper.createLogEvent(
                'Info',
                'Full Application Save Process' + logSaveType,
                'CRM_ApplicationController',
                'saveApplication',
                userInfo.getUserId(),
                'Apex',
                String.valueOf(fullEndTime - fullStartTime)
            )
        );
        response.put('timestamps', timestamps);
        EventBus.publish(logEvents);
        return response;
    }

    private static void undeleteTempRecords(String appId, String accountId) {
        List<Account> accounts = [
            SELECT Id
            FROM Account
            WHERE Id = :accountId AND IsDeleted = TRUE
            ALL ROWS
        ];

        if (accounts != null && accounts.size() == 1) {
            undelete accounts;
        }

        List<Application__c> apps = [
            SELECT Id
            FROM Application__c
            WHERE Id = :appId AND IsDeleted = TRUE
            ALL ROWS
        ];

        if (apps != null && apps.size() == 1) {
            undelete apps;
        }
    }

    // Returns a list of person accounts to be upserted, populating fields based on incoming Applicant_Info__c
    // field values and calling a duplicate prevention service to append IDs as needed
    private static Map<String, Map<Account, Account>> buildPersonAccounts(
        Application__c app,
        Id subscriberAccId,
        List<Applicant_Info__c> applicants,
        Boolean isNew
    ) {
        List<Account> response = new List<Account>();
        Id subscriberId;
        for (Applicant_Info__c applicant : applicants) {
            String accId;
            if (applicant.Primary_Applicant__c && isNew) {
                accId = subscriberAccId;
                subscriberId = subscriberAccId;
            } else {
                accId = applicant.Applicant_Account_ID__c;
            }
            Account acc = new Account(
                Id = accId,
                RecordTypeId = GlobalConstants.individualRT,
                ACA_Paper_Application__c = app.ACA_Paper_Application__c,
                WA_Paper_Application__c = app.WA_Paper_Application__c,
                FirstName = applicant.First_Name__c,
                LastName = applicant.Last_Name__c,
                Middle_Name__pc = applicant.Middle_Name__c,
                DOB__pc = applicant.Birth_Date__c,
                SSN__pc = applicant.SSN__c,
                Gender__pc = applicant.Sex__c,
                Home_Phone__pc = app.Home_Phone__c,
                PersonMailingStreet = app.Mailing_Address__c,
                PersonMailingCity = app.Mailing_City__c,
                PersonMailingState = app.Mailing_State__c,
                PersonMailingPostalCode = app.Mailing_Zip__c,
                PersonMailingCountry = COUNTRY_USA,
                Mailing_County__pc = app.Mailing_County__c,
                ShippingStreet = app.Street_Address__c,
                ShippingCity = app.Street_City__c,
                ShippingState = app.Street_State__c,
                ShippingPostalCode = app.Street_Zip__c,
                ShippingCountry = COUNTRY_USA,
                County__pc = app.Street_County__c,
                BillingStreet = app.Billing_Address__c,
                BillingCity = app.Billing_City__c,
                BillingState = app.Billing_State__c,
                BillingPostalCode = app.Billing_Zip__c,
                BillingCountry = COUNTRY_USA,
                Billing_County__c = app.Billing_County__c
            );
            if (applicant.Primary_Applicant__c) {
                acc.PersonEmail = app.E_mail_Address__c;
                acc.Phone = app.Work_Phone__c;
                acc.PersonMobilePhone = app.Mobile_Phone__c;
            }
            response.add(acc);
        }
        Map<String, Map<Account, Account>> returnResponse = new Map<String, Map<Account, Account>>();
        Map<Account, Account> upsertAccounts = new Map<Account, Account>();
        Map<Account, Account> mergeAccounts = new Map<Account, Account>();

        // For subscriber accounts created with temp values, find and use the ID of any original duplicate account
        // For all other applicants, append IDs of any pre-existing duplicate accounts on insert only
        Map<Account, List<Id>> dupeIdMap = DuplicatePersonAccountCheck.findDuplicateIds(
            response
        );
        for (Account acc : response) {
            List<Id> dupeIds = dupeIdMap.get(acc);
            if (
                dupeIds != null &&
                dupeIds.size() > 0 &&
                (isNew || String.isBlank(acc.Id))
            ) {
                if (acc.Id == null) {
                    acc.id = dupeIds[0];
                } else if (isNew) {
                    Account newMergingAccount = new Account(Id = acc.Id);
                    Account newMasterAccount = new Account(
                        Id = acc.id == dupeIds[0] ? dupeIds[1] : dupeIds[0]
                    );
                    // Overwrite existing values on the master account with the newly entered field values
                    transferSObjectFieldValues(newMasterAccount, acc, false);
                    mergeAccounts.put(newMasterAccount, newMergingAccount);
                }
            }
            upsertAccounts.put(acc, null);
        }
        returnResponse.put('upsertAccounts', upsertAccounts);
        returnResponse.put('mergeAccounts', mergeAccounts);
        return returnResponse;
    }

    // Returns a set of Applicant_Info__c, Account and Prior_Coverage__c Ids for records that should be deleted
    private static List<Id> getApplicantIdsToDelete(
        List<Applicant_Info__c> applicantsToDelete,
        List<Prior_Coverage__c> pcToDelete
    ) {
        List<Id> combinedRecordIds = new List<Id>();
        List<Id> personContactIds = new List<Id>();
        List<Id> applicantIds = new List<Id>();
        for (Prior_Coverage__c pc : pcToDelete) {
            combinedRecordIds.add(pc.Id);
        }
        for (Applicant_Info__c applicant : applicantsToDelete) {
            personContactIds.add(applicant.Applicant__c);
            applicantIds.add(applicant.Id);
            combinedRecordIds.add(applicant.Id);
        }
        // Get person accounts that don't have unrelated Applicant_Info__c records attached
        // Note that Applicant_Info__c.Applicant__c looks up to Contact object, not Account
        for (Contact c : [
            SELECT Id, AccountId
            FROM Contact
            WHERE
                Id IN :personContactIds
                AND Id NOT IN (
                    SELECT Applicant__c
                    FROM Applicant_Info__c
                    WHERE Id NOT IN :applicantIds
                )
        ]) {
            combinedRecordIds.add(c.AccountId);
        }
        return combinedRecordIds;
    }

    //Returns the list of Enrollment Validation Errors currently on an Application
    private static List<Enrollment_Validation_Error__c> getEnrollmentValidationErrors(
        String applicationId
    ) {
        List<Enrollment_Validation_Error__c> applicationEnrollmentValidationErrors = new List<Enrollment_Validation_Error__c>();

        if (
            !String.isBlank(applicationId) &&
            (String.valueOf(((Id) applicationId).getSObjectType())) ==
            'Application__c'
        ) {
            applicationEnrollmentValidationErrors = [
                SELECT
                    Id,
                    Error_Description__c,
                    Error_Owner__c,
                    Prior_Coverage__c,
                    LastModifiedDate,
                    Application__c,
                    ACA_Paper_Application__c,
                    Non_ACA_Paper_Application__c
                FROM Enrollment_Validation_Error__c
                WHERE Application__c = :applicationId
            ];
        }

        return applicationEnrollmentValidationErrors;
    }

    private static List<OpportunityLineItem> buildOppLineItems(
        List<OpportunityLineItem> oppLineItems,
        Opportunity opp
    ) {
        if (oppLineItems != null && oppLineItems.size() > 0 && opp != null) {
            for (OpportunityLineItem item : oppLineItems) {
                // If the line item is new, assign it to the Opportunity
                if (String.isBlank(item.Id)) {
                    item.OpportunityId = opp.Id;
                }
                // If processing complete checkbox is checked, mark it "Offered"
                if (opp.Application_Processing_Complete__c) {
                    item.Offered__c = true;
                }
            }
        }
        return oppLineItems;
    }

    private static Opportunity getOpportunity(String oppId) {
        List<Opportunity> opp = [
            SELECT
                Id,
                Name,
                AccountId,
                Effective_Date__c,
                Application_Received__c,
                Application_Complete__c,
                Application_Received_in_UW__c,
                LOB__c,
                Type_of_Application__c,
                Producer__r.Id,
                Producer__r.FirstName,
                Producer__r.LastName,
                Producer__c,
                Created_Through_WA_Paper_App__c,
                Producer__r.COCE__c,
                Service_Area__c,
                Service_Area__r.Name,
                Service_Area__r.ExtAreaID__c,
                Service_Area__r.Medical_Questionnaire__c,
                RecordTypeId,
                RecordType.Name,
                RADAR_DCN_1__c,
                Radar_DCN_2__c,
                Radar_DCN_3__c,
                Radar_DCN_4__c,
                Enroll_During_Annual_OE__c,
                Stop_Membership_Autoload__c,
                UW_Decision__c,
                Child_Only_Application__c,
                Bridgespan_Off_Exchange__c,
                Bridgespan_On_Exchange__c,
                StageName,
                CloseDate,
                Producer_Lookup_Filter_Value__c,
                Agent_Audit_Reason__c,
                Application_Processing_Complete__c,
                ACA_Paper_Application__c,
                Non_ACA_Paper_Application__c,
                Application__r.Id,
                Application__r.Name,
                Application__r.Ready_To_Submit_To_Facets__c,
                Application__r.Mailing_Address__c,
                Application__r.Mailing_City__c,
                Application__r.Mailing_State__c,
                Application__r.Mailing_Zip__c,
                Application__r.Mailing_County__c,
                Application__r.Street_Address__c,
                Application__r.Street_City__c,
                Application__r.Street_State__c,
                Application__r.Street_Zip__c,
                Application__r.Street_County__c,
                Application__r.Billing_Address__c,
                Application__r.Billing_City__c,
                Application__r.Billing_State__c,
                Application__r.Billing_Zip__c,
                Application__r.Billing_County__c,
                Application__r.E_mail_Address__c,
                Application__r.Work_Phone__c,
                Application__r.Home_Phone__c,
                Application__r.Method_of_Payment__c,
                Application__r.Surepay_Authorization_Date__c,
                Application__r.Surepay_Transaction_Day__c,
                Application__r.EFT_Payer_Name__c,
                (
                    SELECT
                        Id,
                        Name,
                        Weight__c,
                        Use_of_Tobacco__c,
                        WSHIP_Applicant_Signature_Date__c,
                        Signature_Relationship__c,
                        Sex__c,
                        SSN__c,
                        Replace_Current_Coverage__c,
                        RecordTypeId,
                        Primary_Applicant__c,
                        WSHIP_Personal_Rep_Relationship__c,
                        WSHIP_Personal_Representative_Last_Name__c,
                        Applicant_Signature_Date__c,
                        WSHIP_Personal_Representative_First_Name__c,
                        Opportunity__c,
                        Name_of_Insurance_Carrier__c,
                        Middle_Name__c,
                        Height_Inches__c,
                        Height_Feet__c,
                        First_Name__c,
                        Applicant_Signature__c,
                        WSHIP_Applicant_Signature__c,
                        Currently_Have_Coverage__c,
                        WSHIP_Cancellation_Effective_Date__c,
                        WSHIP_Cancel_Current_Coverage__c,
                        WSHIP_Cancel_Current_Coverage_Signature__c,
                        Birth_Date__c,
                        Application__c,
                        Application__r.Proposed_Effective_Date__c,
                        Application_Date__c,
                        Applicant__c,
                        Applicant_Relationship__c,
                        Applicant_Non_Smoker_Signature__c,
                        WSHIP_Applicant_Non_Smoker_Sig_Date__c,
                        Applicant_Age__c,
                        Applicant_Age_on_Effective_Date__c,
                        Applicant_Decision__c,
                        Applicant__r.Account.RecordTypeId,
                        Network__c,
                        Address_Same_As_Subscriber__c,
                        Guardian_Exists__c,
                        Employer__c,
                        Applicant_Employer_Group_Insurer__c,
                        Job_Title__c,
                        Hours_Week__c,
                        Custody_Type__c,
                        Custody_Award_Date__c,
                        Custody_Coverage_Provided_By__c,
                        Employer_Offers_HIS__c,
                        Self_Employed__c,
                        Self_Employed_Business__c,
                        Full_or_Part_Time_Employees__c,
                        HIP_UT_Cert__c,
                        Part_A_Hospital__c,
                        Part_B_Physician__c,
                        Federal_SEP_Reasons__c,
                        Plan_Specific_SEP_Reasons__c,
                        SEP_Other__c,
                        SEP_Reason_Event_Date__c,
                        Medigap_Exempt__c
                    FROM Applicants_Info__r
                )
            FROM Opportunity
            WHERE Id = :oppId
        ];

        if (opp.size() > 0) {
            return opp.get(0);
        }
        return null;
    }

    private static Application__c buildApplication(
        Application__c app,
        Opportunity opp,
        Id appRecordTypeId
    ) {
        // Push all populated field values from incoming app to triggerCreatedApp
        Application__c triggerCreatedApp = (Application__c) transferSObjectFieldValues(
            opp.Application__r,
            app,
            true
        );
        triggerCreatedApp = applyApplicationDefaults(triggerCreatedApp);
        if (opp.RecordType.Name == GlobalConstants.OPP_RECORDTYPE_ACA_NEW_IND) {
            triggerCreatedApp.RecordTypeId = appRecordTypeId;
        }

        //Populate special rule fields
        if (triggerCreatedApp.Surepay_Authorization_Date__c != null) {
            triggerCreatedApp.Payment_Authorization_Signature__c = triggerCreatedApp.EFT_Payer_Name__c;
        }
        return triggerCreatedApp;
    }

    //Assign any default rules on the application object
    private static Application__c applyApplicationDefaults(Application__c app) {
        //if the method of payment is EFT, transaction day should be defaulted to 5
        if (
            app.Method_of_Payment__c == GlobalConstants.MethodOfPaymentEFT &&
            String.isBlank(app.Surepay_Transaction_Day__c)
        ) {
            app.Surepay_Transaction_Day__c = '5';
        }
        return app;
    }

    // Create a list of Applicant_Info__c records to upsert based on incoming data, pre-existing records,
    // and trigger-created record IDs
    private static List<Applicant_Info__c> buildApplicants(
        List<Applicant_Info__c> applicants,
        List<Applicant_Info__c> existingApplicants,
        Id applicationId,
        Id opportunityId,
        List<Account> personAccounts,
        Id applicantRecordTypeId
    ) {
        List<Applicant_Info__c> response = new List<Applicant_Info__c>();
        List<Id> personAccountIds = new List<Id>();
        for (Account a : personAccounts) {
            personAccountIds.add(a.Id);
        }
        List<Account> personAccountsWithContactId = [
            SELECT Id, FirstName, LastName, DOB__pc, Gender__pc, PersonContactId
            FROM Account
            WHERE Id IN :personAccountIds
        ];
        for (Applicant_Info__c applicant : applicants) {
            Boolean isAdded = false;
            // For new applicant records, populate relationship fields
            if (String.isBlank(applicant.Id)) {
                applicant.Application__c = applicationId;
                applicant.Opportunity__c = opportunityId;
                applicant.RecordTypeId = applicantRecordTypeId;
                for (Account acc : personAccountsWithContactId) {
                    if (
                        acc.FirstName == applicant.First_Name__c &&
                        acc.LastName == applicant.Last_Name__c &&
                        acc.DOB__pc == applicant.Birth_Date__c &&
                        acc.Gender__pc == applicant.Sex__c
                    ) {
                        applicant.Applicant__c = acc.PersonContactId;
                    }
                }
            }

            // If the record already exists in the database, write new values to that record and add to the response list
            for (Applicant_Info__c existing : existingApplicants) {
                if (
                    (applicant.Primary_Applicant__c &&
                    existing.Primary_Applicant__c) ||
                    applicant.Id == existing.Id
                ) {
                    response.add(
                        (Applicant_Info__c) transferSObjectFieldValues(
                            existing,
                            applicant,
                            true
                        )
                    );
                    isAdded = true;
                }
            }
            if (!isAdded) {
                response.add(applicant);
            }
        }
        return response;
    }

    private static List<Prior_Coverage__c> buildPriorCoverages(
        List<Prior_Coverage__c> pcToUpsert
    ) {
        for (Prior_Coverage__c pc : pcToUpsert) {
            Applicant_Info__c lookupApplicant = new Applicant_Info__c(
                External_ID__c = pc.Applicant_External_ID__c
            );
            pc.Applicant_Info__r = lookupApplicant;
        }
        return pcToUpsert;
    }

    // Push all populated, updateable field values from one SObject to another SObject of the same type
    private static SObject transferSObjectFieldValues(
        SObject targetObject,
        SObject sourceObject,
        Boolean writeBlank
    ) {
        Map<String, Schema.SObjectField> fieldMap = targetObject.getsObjectType()
            .getDescribe()
            .fields.getMap();
        Map<String, Object> sourceFields = sourceObject.getPopulatedFieldsAsMap();
        for (String fieldName : sourceFields.keySet()) {
            Object value = sourceFields.get(fieldName);
            if (
                fieldMap.containsKey(fieldName) &&
                fieldMap.get(fieldName).getDescribe().isUpdateable() &&
                (writeBlank ||
                (value != null &&
                !(value instanceof String && String.isBlank((String) value))))
            ) {
                targetObject.put(fieldName, sourceFields.get(fieldName));
            }
        }
        return targetObject;
    }

    @AuraEnabled
    public static void deleteRecords(List<String> appIds) {
        // Delete the applications and their detail records
        List<Application__c> appsToDelete = new List<Application__c>();
        for (String appId : appIds) {
            appsToDelete.add(new Application__c(Id = appId));
        }
        // Delete related person accounts and their detail records, but not if there is more than one Applicant Info record tied to it
        List<Account> accountsToDelete = new List<Account>();
        for (Account acc : [
            SELECT Id, (SELECT Id FROM ApplicantsInfo__pr)
            FROM Account
            WHERE
                PersonContactId IN (
                    SELECT Applicant__c
                    FROM Applicant_Info__c
                    WHERE Application__c IN :appIds
                )
        ]) {
            if (
                acc.ApplicantsInfo__pr == null ||
                acc.ApplicantsInfo__pr.size() < 2
            ) {
                accountsToDelete.add(acc);
            }
        }
        delete accountsToDelete;
        delete appsToDelete;
    }

    private static Map<String, Object> newTimestamp(String eventDescription) {
        return new Map<String, Object>{
            'event' => eventDescription,
            'ms' => DateTime.now().getTime()
        };
    }

    /**
     * Supports case-insensitive sorting (ascending) of SObjects by an ordered
     * list of String- or Decimal-type field API names
     */
    private static Integer compareSobjects(
        SObject obj1,
        SObject obj2,
        List<String> fieldNames
    ) {
        for (String field : fieldNames) {
            Integer res = compareSobjects(obj1, obj2, field);
            if (res != 0)
                return res;
        }
        return 0;
    }
    /**
     * Supports case-insensitive sorting (ascending) of SObjects given a String
     * or Decimal-type field API name
     */
    private static Integer compareSobjects(
        SObject obj1,
        SObject obj2,
        String fieldName
    ) {
        if (obj1.get(fieldName) instanceof String) {
            String thisVal = ((String) obj1.get(fieldName)).toUpperCase();
            String otherVal = ((String) obj2.get(fieldName)).toUpperCase();
            if (thisVal == otherVal)
                return 0;
            if (thisVal > otherVal)
                return 1;
            return -1;
        } else if (obj1.get(fieldName) instanceof Decimal) {
            if ((Decimal) obj1.get(fieldName) == (Decimal) obj2.get(fieldName))
                return 0;
            if ((Decimal) obj1.get(fieldName) > (Decimal) obj2.get(fieldName))
                return 1;
            return -1;
        }
        return 1;
    }
}
