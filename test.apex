@isTest
public class CRM_ApplicationControllerTest {
    @TestSetup
    static void makeData() {
        Test.startTest();
        // BUILD LOOKUP DATA
        TestRecordUtility.createServiceAreaRecords();
        TestRecordUtility.createMedicalNeighborhoods();
        TestRecordUtility.createProductsAndClasses();
        TestRecordUtility.createZipCountyNetworkMaps();
        TestRecordUtility.createProductFilterId();
        Product_Class__c productClass = [
            SELECT Id, Product_Filter__c, Description__c, Product__c
            FROM Product_Class__c
            WHERE Service_Area__r.ExtAreaID__c = 'OR'
            LIMIT 1
        ];
        Product_Filter__c pf = [SELECT Id FROM Product_Filter__c LIMIT 1];
        PricebookEntry pbe = [
            SELECT Id, UnitPrice
            FROM PricebookEntry
            WHERE Product2Id = :productClass.Product__c
            LIMIT 1
        ];
        productClass.Product_Filter__c = pf.Id;
        update productClass;
        List<ZipCountyServiceAreaMap__c> zcsams = new List<ZipCountyServiceAreaMap__c>{
            new ZipCountyServiceAreaMap__c(
                ExtAreaID__c = 'Clark Co',
                Zip_Code__c = '98101',
                County__c = 'CLARK'
            ),
            new ZipCountyServiceAreaMap__c(
                ExtAreaID__c = 'OR',
                Zip_Code__c = '97212',
                County__c = 'MULTNOMAH'
            )
        };
        for (ZipCountyServiceAreaMap__c zcsam : zcsams) {
            zcsam.Name = 'Test' + zcsam.ExtAreaID__c;
            zcsam.Service_Area__c = zcsam.ExtAreaID__c;
            zcsam.Start_Date__c = Date.newInstance(2018, 1, 1);
            zcsam.End_Date__c = Date.newInstance(2199, 12, 31);
            zcsam.LOB__c = GlobalConstants.MedigapLOB;
        }
        insert zcsams;

        // BUILD ONE PRE-EXISTING <65 OFF EXCHANGE APPLICATION
        TestRecordUtility.IndyApp ia = new TestRecordUtility.IndyApp(
            'OR',
            GlobalConstants.IndividualLOB
        );
        ia.opp.Effective_Date__c = Date.valueOf('2020-07-01');
        ia.app.Street_Zip__c = '97201';
        ia.app.Street_County__c = 'Multnomah';
        ia.acc.FirstName = 'TestSubscriber';
        ia.acc.LastName = 'TestLast';
        ia.subscriber.External_ID__c = 'TEMPID00001';
        ia.addDependent('Legal Spouse', 'TestSpouse', 'TestLast', null, null);
        ia.applicants[1].External_ID__c = 'TEMPID00002';
        ia.addDependent('Child', 'TestChild', 'TestLast', null, null);
        ia.applicants[2].External_ID__c = 'TEMPID00003';
        ia.insertAll();
        OpportunityLineItem lineItem = new OpportunityLineItem(
            OpportunityId = ia.opp.Id,
            Applied_For__c = true,
            Quantity = 1,
            Product_Class__c = productClass.Id,
            Description = productClass.Description__c,
            PricebookEntryId = pbe.Id,
            UnitPrice = pbe.UnitPrice,
            ServiceDate = Date.today()
        );
        insert lineItem;
        List<Prior_Coverage__c> pcs = new List<Prior_Coverage__c>();
        for (Applicant_Info__c ai : ia.applicants) {
            pcs.add(
                new Prior_Coverage__c(
                    Applicant_Info__c = ai.Id,
                    Applicant_External_ID__c = ai.External_ID__c,
                    ACA_Type_of_Prior_Coverage__c = 'Employer Group',
                    Insurer_Name__c = 'Acme Insurance, Inc.',
                    Policy_Number__c = 'P-8675309',
                    Coverage_From__c = Date.newInstance(2005, 1, 1),
                    Coverage_To__c = Date.newInstance(2020, 1, 31),
                    Benefit_Type__c = 'Medical'
                )
            );
        }
        insert pcs;
        Enrollment_Validation_Error__c enrollmentValidationError = new Enrollment_Validation_Error__c(
            Application__c = ia.app.Id,
            Error_Description__c = 'Mock',
            Error_Owner__c = 'Non-Enrollment'
        );
        insert enrollmentValidationError;

        Test.stopTest();
    }

    @isTest
    public static void testGetDataWithId() {
        Application__c testApp = [
            SELECT
                Id,
                Opportunity__c,
                Street_Zip__c,
                Street_County__c,
                (SELECT Id, Applicant_Relationship__c FROM Applicants_Info__r)
            FROM Application__c
            LIMIT 1
        ];
        List<Applicant_Info__c> applicants = testApp.Applicants_Info__r;
        System.assertEquals(3, applicants.size());
        List<OpportunityLineItem> oppLineItems = [
            SELECT Id, Product_Class__c, Description
            FROM OpportunityLineItem
            WHERE OpportunityId = :testApp.Opportunity__c
        ];
        System.assertEquals(1, oppLineItems.size());
        List<Enrollment_Validation_Error__c> enrollmentErrors = [
            SELECT Application__c
            FROM Enrollment_Validation_Error__c
            WHERE Application__c = :testApp.Id
        ];
        System.assertEquals(
            1,
            enrollmentErrors.size(),
            'An error occurred when inserting an Enrollment Validation Error inside the Trigger/Process Builder'
        );
        Test.startTest();
        Map<String, Object> res = CRM_ApplicationController.getData(
            testApp.Id,
            'OR',
            GlobalConstants.IndividualLOB,
            Date.today(),
            false,
            testApp.Street_Zip__c,
            testApp.Street_County__c
        );
        List<Applicant_Info__c> resApplicants = (List<Applicant_Info__c>) res.get(
            'applicants'
        );
        System.assertEquals(3, resApplicants.size());
        Integer foundApplicantCount = 0;
        for (Applicant_Info__c applicant : applicants) {
            for (Applicant_Info__c a : resApplicants) {
                if (
                    a.Id == applicant.Id &&
                    a.Applicant_Relationship__c ==
                    applicant.Applicant_Relationship__c
                ) {
                    foundApplicantCount++;
                }
            }
        }
        System.assertEquals(3, foundApplicantCount);
        List<Map<String, Object>> resProducts = (List<Map<String, Object>>) res.get(
            'products'
        );
        System.assertEquals(2, resProducts.size());
        List<Medical_Neighborhoods__c> resMedicalNeighborhoods = (List<Medical_Neighborhoods__c>) res.get(
            'medicalNeighborhoods'
        );
        // TestRecordUtility method only creates medical neighborhoods for Idaho, not Oregon
        System.assertEquals(0, resMedicalNeighborhoods.size());
        List<OpportunityLineItem> resOppLineItems = (List<OpportunityLineItem>) res.get(
            'oppLineItems'
        );
        System.assertEquals(1, resOppLineItems.size());
        System.assertEquals(
            oppLineItems[0].Product_Class__c,
            resOppLineItems[0].Product_Class__c
        );
        System.assertEquals(
            oppLineItems[0].Description,
            resOppLineItems[0].Description
        );
        List<Enrollment_Validation_Error__c> resEnrollmentErrors = (List<Enrollment_Validation_Error__c>) res.get(
            'enrollmentValidationErrors'
        );
        System.assertEquals(
            1,
            resEnrollmentErrors.size(),
            'Enrollment Validation Error was not retrieved using the controller!'
        );
        System.assertEquals(
            enrollmentErrors[0].Application__c,
            resEnrollmentErrors[0].Application__c,
            'Enrollment Validation Error was not retrieved for the right Application!'
        );
        Map<String, Id> recordTypeIds = (Map<String, Id>) res.get(
            'recordTypeIds'
        );
        System.assertEquals(4, recordTypeIds.size());
        System.assertEquals(
            GlobalConstants.individualRT,
            recordTypeIds.get('Account')
        );
        System.assertEquals(
            GlobalConstants.ApplicationRecordTypeId,
            recordTypeIds.get('Application__c')
        );
        System.assertEquals(
            GlobalConstants.individualNewACART,
            recordTypeIds.get('Opportunity')
        );
        System.assertEquals(
            GlobalConstants.ApplicantInfoRecordTypeId,
            recordTypeIds.get('Applicant_Info__c')
        );
        Test.stopTest();
    }

    @isTest
    static void testGetDataWithoutId_ID() {
        testGetDataWithoutId(
            'ID',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            new Set<String>{
                '83201|Bannock',
                '83232|Franklin',
                '83333|Blaine'
            },
            null,
            true
        );
    }

    @isTest
    static void testGetDataWithoutId_Asuris_2020() {
        testGetDataWithoutId(
            'Asuris',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            new Set<String>{
                '99402|Asotin',
                '99111|Whitman',
                '99344|Grant',
                '99344|Adams'
            },
            new Set<String>{
                '99001|Spokane',
                '99323|Walla Walla',
                '99008|Lincoln',
                '99110|Stevens'
            },
            false
        );
    }

    @isTest
    static void testGetDataWithoutId_Asuris_2021() {
        testGetDataWithoutId(
            'Asuris',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            false,
            new Set<String>{
                '99402|Asotin',
                '99111|Whitman',
                '99344|Grant',
                '99344|Adams',
                '99001|Spokane',
                '99323|Walla Walla',
                '99008|Lincoln',
                '99110|Stevens'
            },
            null,
            false
        );
    }

    @isTest
    static void testGetDataWithoutId_OR_2020() {
        testGetDataWithoutId(
            'OR',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            new Set<String>{
                '97001|Wasco',
                '97110|Clatsop',
                '97222|Clackamas',
                '97401|Lane'
            },
            new Set<String>{ '97530|Jackson', '97601|Klamath', '97026|Marion' },
            false
        );
    }

    @isTest
    static void testGetDataWithoutId_OR_2021() {
        testGetDataWithoutId(
            'OR',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            false,
            new Set<String>{
                '97001|Wasco',
                '97110|Clatsop',
                '97222|Clackamas',
                '97401|Lane',
                '97530|Jackson',
                '97601|Klamath',
                '97026|Marion'
            },
            null,
            false
        );
    }

    @isTest
    static void testGetDataWithoutId_Medigap() {
        testGetDataWithoutId(
            'OR',
            GlobalConstants.MedigapLOB,
            Date.newInstance(2020, 1, 1),
            false,
            // Note: full ZipCountyServiceArea__c data is not inserted in the
            // test setup method -- testing just one zip code here
            new Set<String>{ '97212|Multnomah' },
            new Set<String>{ '97372|Lincoln', '98101|Clark' },
            false
        );
    }

    @isTest
    static void testGetDataWithoutId_WARBS_2020() {
        testGetDataWithoutId(
            'WA',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            new Set<String>{
                '98001|King',
                '98401|Pierce',
                '99360|Walla Walla',
                '98901|Yakima'
            },
            new Set<String>{
                '98020|Snohomish',
                '98110|Kitsap',
                '98222|San Juan',
                '98305|Clallam',
                '98601|Cowlitz',
                '98602|Klickitat',
                '99301|Franklin'
            },
            false
        );
    }

    @isTest
    static void testGetDataWithoutId_WARBS_2021() {
        testGetDataWithoutId(
            'WA',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            false,
            new Set<String>{
                '98001|King',
                '98020|Snohomish',
                '98201|Snohomish',
                '98222|San Juan',
                '98401|Pierce',
                '98305|Clallam',
                '98110|Kitsap',
                '98601|Cowlitz',
                '98602|Klickitat'
            },
            new Set<String>{ '99301|Franklin', '99360|Walla Walla' },
            false
        );
    }

    @isTest
    static void testGetDataWithoutId_WARBS_2020_Bridgespan() {
        testGetDataWithoutId(
            'WA',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            true,
            new Set<String>{
                '98602|Klickitat',
                '98901|Yakima',
                '99301|Franklin',
                '99360|Walla Walla'
            },
            new Set<String>{
                '98001|King',
                '98201|Snohomish',
                '98222|San Juan',
                '98401|Pierce',
                '98601|Cowlitz',
                '99001|Spokane'
            },
            false
        );
    }

    @isTest
    static void testGetDataWithoutId_WARBS_2021_Bridgespan() {
        testGetDataWithoutId(
            'WA',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            true,
            new Set<String>{
                '98001|King',
                '98201|Snohomish',
                '98401|Pierce',
                '98602|Klickitat',
                '98901|Yakima',
                '99301|Franklin',
                '99360|Walla Walla',
                '99001|Spokane'
            },
            new Set<String>{ '98601|Cowlitz', '98222|San Juan' },
            false
        );
    }

    private static void testGetDataWithoutId(
        String serviceArea,
        String lob,
        Date effDate,
        Boolean isBridgeSpan,
        Set<String> expectedZipCounties,
        Set<String> unexpectedZipCounties,
        Boolean expectMedicalNeighborhoods
    ) {
        // Setting Service Area to Idaho to make sure the method can return Medical Neighborhood records where appropriate
        Map<String, Object> res = CRM_ApplicationController.getData(
            null,
            serviceArea,
            lob,
            effDate,
            isBridgeSpan,
            null,
            null
        );
        List<Applicant_Info__c> resApplicants = (List<Applicant_Info__c>) res.get(
            'applicants'
        );
        System.assertEquals(1, resApplicants.size());
        System.assertEquals(null, resApplicants[0].Last_Name__c);
        List<OpportunityLineItem> resOppLineItems = (List<OpportunityLineItem>) res.get(
            'oppLineItems'
        );
        System.assertEquals(1, resOppLineItems.size());
        System.assertEquals(
            GlobalConstants.Subscriber,
            resApplicants[0].Applicant_Relationship__c
        );
        List<Map<String, String>> resZipCounties = (List<Map<String, String>>) res.get(
            'zipCounties'
        );
        System.assertNotEquals(0, resZipCounties.size());
        Set<String> zcsReturned = new Set<String>();
        for (Map<String, String> zc : resZipCounties) {
            zcsReturned.add(
                zc.get('zip') +
                '|' +
                zc.get('county').toUpperCase()
            );
        }
        if (expectedZipCounties != null && expectedZipCounties.size() > 0) {
            for (String zc : expectedZipCounties) {
                System.assert(
                    zcsReturned.contains(zc.toUpperCase()),
                    'Expected to find zip + county ' + zc
                );
            }
        }
        if (unexpectedZipCounties != null && unexpectedZipCounties.size() > 0) {
            for (String zc : unexpectedZipCounties) {
                System.assert(
                    !zcsReturned.contains(zc.toUpperCase()),
                    'Did not expect to find zip + county ' + zc
                );
            }
        }

        List<Medical_Neighborhoods__c> resMedicalNeighborhoods = (List<Medical_Neighborhoods__c>) res.get(
            'medicalNeighborhoods'
        );
        if (expectMedicalNeighborhoods) {
            System.assertNotEquals(0, resMedicalNeighborhoods.size());
        } else {
            System.assertEquals(0, resMedicalNeighborhoods.size());
        }

        List<Map<String, Object>> resProducts = (List<Map<String, Object>>) res.get(
            'products'
        );
        // For Medigap, return products right away. For <65, wait until zip +
        // county are populated
        if (lob == GlobalConstants.MedigapLOB) {
            System.assertNotEquals(0, resProducts.size());
        } else {
            System.assertEquals(0, resProducts.size());
        }
    }

    @isTest
    public static void testGetDataWithoutId_MedigapWA() {
        Map<String, Object> res = CRM_ApplicationController.getData(
            null,
            'Clark Co',
            GlobalConstants.MedigapLOB,
            Date.today(),
            false,
            null,
            null
        );
        List<Applicant_Info__c> resApplicants = (List<Applicant_Info__c>) res.get(
            'applicants'
        );
        System.assertEquals(1, resApplicants.size());
        System.assertEquals(null, resApplicants[0].Last_Name__c);
        List<OpportunityLineItem> resOppLineItems = (List<OpportunityLineItem>) res.get(
            'oppLineItems'
        );
        System.assertEquals(1, resOppLineItems.size());
        System.assertEquals(
            GlobalConstants.Subscriber,
            resApplicants[0].Applicant_Relationship__c
        );
        Map<String, Id> recordTypeIds = (Map<String, Id>) res.get(
            'recordTypeIds'
        );
        System.assertEquals(4, recordTypeIds.size());
        System.assertEquals(
            GlobalConstants.individualRT,
            recordTypeIds.get('Account')
        );
        System.assertEquals(
            MetaUtils.getRecordTypeId(
                Application__c.SObjectType,
                'Unsubmitted'
            ),
            recordTypeIds.get('Application__c')
        );
        System.assertEquals(
            GlobalConstants.individualNewWART,
            recordTypeIds.get('Opportunity')
        );
        System.assertEquals(
            MetaUtils.getRecordTypeId(
                Applicant_Info__c.SObjectType,
                'Unsubmitted'
            ),
            recordTypeIds.get('Applicant_Info__c')
        );
    }

    @isTest
    public static void testGetDataWithoutId_MedigapOR() {
        Map<String, Object> res = CRM_ApplicationController.getData(
            null,
            'OR',
            GlobalConstants.MedigapLOB,
            Date.today(),
            false,
            null,
            null
        );
        List<Applicant_Info__c> resApplicants = (List<Applicant_Info__c>) res.get(
            'applicants'
        );
        System.assertEquals(1, resApplicants.size());
        System.assertEquals(null, resApplicants[0].Last_Name__c);
        List<OpportunityLineItem> resOppLineItems = (List<OpportunityLineItem>) res.get(
            'oppLineItems'
        );
        System.assertEquals(1, resOppLineItems.size());
        System.assertEquals(
            GlobalConstants.Subscriber,
            resApplicants[0].Applicant_Relationship__c
        );
        Map<String, Id> recordTypeIds = (Map<String, Id>) res.get(
            'recordTypeIds'
        );
        System.assertEquals(4, recordTypeIds.size());
        System.assertEquals(
            GlobalConstants.individualRT,
            recordTypeIds.get('Account')
        );
        System.assertEquals(
            MetaUtils.getRecordTypeId(
                Application__c.SObjectType,
                'Unsubmitted'
            ),
            recordTypeIds.get('Application__c')
        );
        System.assertEquals(
            MetaUtils.getRecordTypeId(
                Opportunity.SObjectType,
                'Individual - New - ID/OR/UT'
            ),
            recordTypeIds.get('Opportunity')
        );
        System.assertEquals(
            MetaUtils.getRecordTypeId(
                Applicant_Info__c.SObjectType,
                'Unsubmitted'
            ),
            recordTypeIds.get('Applicant_Info__c')
        );
        System.assertNotEquals(
            null,
            (List<Map<String, Object>>) res.get('products')
        );
    }

    @isTest
    static void getLookupData_OR_2020() {
        getLookupData(
            'OR',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            '97214',
            'Multnomah',
            new Set<String>{ 'Direct Bronze', 'Direct Silver' },
            new Set<String>{ 'OHSU Plus' }
        );
    }

    @isTest
    static void getLookupData_OR_2021() {
        getLookupData(
            'OR',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            false,
            '97214',
            'Multnomah',
            new Set<String>{ 'Direct Bronze', 'Direct Silver', 'Direct Gold' },
            new Set<String>{
                'Individual and Family Network',
                'Legacy LHP',
                'OHSU Health'
            }
        );
    }

    @isTest
    static void getLookupData_OR_Medigap() {
        getLookupData(
            'OR',
            GlobalConstants.MedigapLOB,
            Date.newInstance(2020, 1, 1),
            false,
            '97214',
            'Multnomah',
            new Set<String>{
                'Regence Bridge Plan A',
                'Regence Bridge Plan C',
                'Regence Bridge Plan F',
                'Regence Bridge Plan G',
                'Regence Bridge Plan K',
                'Regence Bridge Plan N'
            },
            new Set<String>()
        );
    }

    @isTest
    static void getLookupData_OR_Medigap_no_zip_county() {
        getLookupData(
            'OR',
            GlobalConstants.MedigapLOB,
            Date.newInstance(2020, 1, 1),
            false,
            null,
            null,
            // Unlike <65, this should still return products
            new Set<String>{
                'Regence Bridge Plan A',
                'Regence Bridge Plan C',
                'Regence Bridge Plan F',
                'Regence Bridge Plan G',
                'Regence Bridge Plan K',
                'Regence Bridge Plan N'
            },
            new Set<String>()
        );
    }

    @isTest
    static void getLookupData_OR_no_zip_county() {
        getLookupData(
            'OR',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            null,
            null,
            // Should return an empty list of products
            new Set<String>(),
            new Set<String>()
        );
    }

    @isTest
    static void getLookupData_OR_invalid_zip_county() {
        getLookupData(
            'OR',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            '83201', // not in Oregon
            'Bannock', // ""
            // Should return an empty list of products
            new Set<String>(),
            new Set<String>()
        );
    }

    @isTest
    static void getLookupData_ID() {
        getLookupData(
            'ID',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            '83201',
            'Bannock',
            new Set<String>{ 'Direct Bronze', 'Direct Silver' },
            new Set<String>{ 'Individual and Family Network' }
        );
    }

    @isTest
    static void getLookupData_ID_2021_83201() {
        getLookupData(
            'ID',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            false,
            '83201',
            'Bannock',
            new Set<String>{ 'Direct Bronze', 'Direct Silver', 'Direct Gold' },
            new Set<String>{ 'Individual and Family Network' }
        );
    }

    @isTest
    static void getLookupData_ID_2021_83333() {
        getLookupData(
            'ID',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            false,
            '83333',
            'Blaine',
            new Set<String>{ 'Direct Bronze', 'Direct Silver', 'Direct Gold' },
            new Set<String>{ 'St. Luke\'s Health Partners' }
        );
    }

    @isTest
    static void getLookupData_ID_2021_83420() {
        getLookupData(
            'ID',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            false,
            '83420',
            'Fremont',
            new Set<String>{ 'Direct Bronze', 'Direct Silver', 'Direct Gold' },
            new Set<String>{ 'Preferred' }
        );
    }

    @isTest
    static void getLookupData_WA_2020() {
        getLookupData(
            'WA',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2020, 1, 1),
            false,
            '98001',
            'King',
            new Set<String>{ 'Direct Bronze', 'Direct Silver', 'Direct Gold' },
            new Set<String>{ 'UW Medicine' }
        );
    }

    @isTest
    static void getLookupData_WA_2021() {
        getLookupData(
            'WA',
            GlobalConstants.IndividualLOB,
            Date.newInstance(2021, 1, 1),
            false,
            '98001',
            'King',
            new Set<String>{ 'Direct Bronze', 'Direct Silver' },
            new Set<String>{ 'Individual and Family Network' }
        );
    }

    private static void getLookupData(
        String serviceArea,
        String lob,
        Date effDate,
        Boolean isBridgeSpan,
        String zipCode,
        String county,
        Set<String> expectedProducts,
        Set<String> expectedNetworks
    ) {
        Map<String, Object> data = CRM_ApplicationController.getLookupData(
            serviceArea,
            lob,
            effDate,
            isBridgeSpan,
            zipCode,
            county
        );
        List<Map<String, Object>> productData = (List<Map<String, Object>>) data.get(
            'products'
        );
        System.assertNotEquals(null, productData);
        if (expectedProducts != null && expectedProducts.size() > 0) {
            System.assertNotEquals(0, productData.size());
            Set<String> productNames = new Set<String>();
            Set<String> networks = new Set<String>();
            for (Map<String, Object> p : productData) {
                productNames.add((String) p.get('Name'));
                List<Product_Class__c> pcs = (List<Product_Class__c>) p.get(
                    'ProductClassIDs__r'
                );
                System.assertNotEquals(0, pcs.size());
                for (Product_Class__c pc : pcs) {
                    if (String.isNotBlank(pc.Network_Name__c)) {
                        networks.add(pc.Network_Name__c);
                    }
                }
            }
            System.assert(
                productNames.equals(expectedProducts),
                'productNames: ' +
                productNames +
                ' | expectedProducts: ' +
                expectedProducts
            );
            System.assert(
                networks.equals(expectedNetworks),
                'networks: ' +
                networks +
                ' | expectedNetworks: ' +
                expectedNetworks
            );
        } else {
            System.assertEquals(0, productData.size());
        }
    }

    @isTest
    static void testCreateCoreObjectsOffExchange() {
        testCreateCoreObjects(
            GlobalConstants.IndividualLOB,
            false,
            GlobalConstants.ApplicationTypeNewEnrollment,
            true,
            false
        );
    }

    @isTest
    static void testCreateCoreObjectsOnExchange() {
        testCreateCoreObjects(
            GlobalConstants.IndividualLOB,
            true,
            GlobalConstants.ApplicationTypeOnExchangeNew,
            true,
            false
        );
    }

    @isTest
    static void testCreateCoreObjectsMedigap() {
        testCreateCoreObjects(
            GlobalConstants.MedigapLOB,
            false,
            GlobalConstants.ApplicationTypeNewEnrollment,
            false,
            true
        );
    }

    private static void testCreateCoreObjects(
        String lob,
        Boolean isOnExchange,
        String expectedTypeOfApp,
        Boolean expectAcaApp,
        Boolean expectNonAcaApp
    ) {
        Test.startTest();
        Map<String, String> response = CRM_ApplicationController.createCoreObjects(
            'OR',
            lob,
            isOnExchange
        );
        Test.stopTest();
        System.assertEquals(8, response.size());
        System.assert(response.containsKey('personAccount'));
        System.assertNotEquals(null, response.get('personAccount'));
        System.assert(response.containsKey('personContact'));
        System.assertNotEquals(null, response.get('personContact'));
        System.assert(response.containsKey('opp'));
        System.assertNotEquals(null, response.get('opp'));
        System.assert(response.containsKey('app'));
        System.assertNotEquals(null, response.get('app'));
        System.assert(response.containsKey('acaApp'));
        if (expectAcaApp) {
            System.assertNotEquals(null, response.get('acaApp'));
        } else {
            System.assertEquals(null, response.get('acaApp'));
        }
        System.assert(response.containsKey('nonAcaApp'));
        if (expectNonAcaApp) {
            System.assertNotEquals(null, response.get('nonAcaApp'));
        } else {
            System.assertEquals(null, response.get('nonAcaApp'));
        }
        System.assert(response.containsKey('nonAcaApp'));
        System.assert(response.containsKey('serviceArea'));
        System.assertNotEquals(null, response.get('serviceArea'));
        System.assert(response.containsKey('applicant'));
        System.assertNotEquals(null, response.get('applicant'));
        List<Application__c> apps = [
            SELECT
                Id,
                Opportunity__c,
                ACA_Paper_Application__c,
                WA_Paper_Application__c,
                (
                    SELECT Id, Applicant__r.AccountId, Opportunity__c
                    FROM Applicants_Info__r
                )
            FROM Application__c
            WHERE Id = :response.get('app')
            ALL ROWS
        ]; // Remove ALL ROWS when no longer using delete/undelete
        System.assertEquals(
            1,
            apps.size(),
            'Found ' +
            apps.size() +
            ' apps with Id ' +
            response.get('app')
        );
        Application__c app = apps[0];
        System.assertNotEquals(null, app);
        List<Opportunity> opps = [
            SELECT Id, Type_of_Application__c
            FROM Opportunity
            WHERE Id = :response.get('opp')
            ALL ROWS
        ]; // Remove ALL ROWS when no longer using delete/undelete
        Opportunity opp = opps[0];
        System.assertEquals(expectedTypeOfApp, opp.Type_of_Application__c);
        /* Deleted records return without relationship fields -- add these assertions back when no longer using
           delete/undelete
        System.assertEquals(response.get('acaApp'), app.ACA_Paper_Application__c);
        System.assertEquals(response.get('nonAcaApp'), app.WA_Paper_Application__c);
        System.assertEquals(response.get('opp'), app.Opportunity__c);
        System.assertEquals(response.get('personAccount'), app.Opportunity__r.AccountId);
        System.assertEquals(response.get('serviceArea'), app.Opportunity__r.Service_Area__c);
        System.assertEquals(response.get('acaApp'), app.Opportunity__r.ACA_Paper_Application__c);
        System.assertEquals(response.get('nonAcaApp'), app.Opportunity__r.Non_ACA_Paper_Application__c);
        System.assertEquals(response.get('personAccount'), app.Opportunity__r.AccountId);
        System.assertEquals(response.get('acaApp'), app.Opportunity__r.Account.ACA_Paper_Application__c);
        System.assertEquals(response.get('nonAcaApp'), app.Opportunity__r.Account.WA_Paper_Application__c);
        System.assertEquals(1, app.Applicants_Info__r.size());
        Applicant_Info__c applicant = app.Applicants_Info__r[0];
        System.assertEquals(response.get('applicant'), applicant.Id);
        System.assertEquals(response.get('personAccount'), applicant.Applicant__r.AccountId);
        System.assertEquals(response.get('opp'), applicant.Opportunity__c); */
    }

    @isTest
    public static void testCreateCoreObjectsException() {
        // Passing in an invalid service area external ID should result in an exception
        Boolean exceptionCaught = false;
        try {
            Map<String, String> response = CRM_ApplicationController.createCoreObjects(
                'ZZ',
                '>89',
                false
            );
        } catch (Exception e) {
            exceptionCaught = true;
        }
        System.assertEquals(true, exceptionCaught);
    }

    @isTest
    public static void testSaveNewApplication() {
        Map<String, String> coreObjectIds = CRM_ApplicationController.createCoreObjects(
            'OR',
            GlobalConstants.IndividualLOB,
            false
        );
        System.assertNotEquals(null, coreObjectIds);
        System.assertNotEquals(0, coreObjectIds.size());
        String testStreet = '123 Main St.';
        String testCity = 'Portland';
        String testState = 'OR';
        String testZip = '97214';
        String testCounty = 'Multnomah';
        String testServiceArea = 'OR';
        String testFirstName = 'TestFirst';
        String testMiddleName = 'TestMiddle';
        String testLastName = 'TestLast';
        String testGender = 'Female';
        String testSSN = '123-45-6789';
        String testExtId = 'TEMPID8a42cd18-7ba5-483a-99c0-276b3d2e3e66';
        String testPcType = 'COBRA;Medicare';
        String testInsurer = 'Acme Insurance';
        String testPolicyNumber = 'P-012345';
        String testBenefitType = 'Medical';
        Boolean testMedigapExempt = true;
        String testTransferGrid = '0000000';

        Date testDOB = Date.newInstance(1970, 1, 1);
        Date testEffDate = Date.newInstance(2020, 2, 1);
        Date testReqDate = Date.newInstance(2020, 1, 15);
        Date testCoverageFrom = Date.newInstance(2015, 7, 15);
        Date testCoverageTo = Date.newInstance(2020, 1, 31);
        Application__c app = new Application__c(
            Id = coreObjectIds.get('app'),
            Opportunity__c = coreObjectIds.get('opp'),
            Requested_Effective_Date__c = testEffDate,
            Street_Address__c = testStreet,
            Street_City__c = testCity,
            Street_State__c = testState,
            Street_Zip__c = testZip,
            Street_County__c = testCounty,
            Is_Street_Address_Validated__c = false,
            Method_of_Payment__c = null,
            Surepay_Transaction_Day__c = null,
            Surepay_Authorization_Date__c = Date.Today(),
            EFT_Payer_Name__c = 'Test'
        );
        Opportunity opp = new Opportunity(
            Id = coreObjectIds.get('opp'),
            AccountId = coreObjectIds.get('personAccount'),
            Application__c = coreObjectIds.get('app'),
            Effective_Date__c = testEffDate,
            Application_Received__c = testReqDate,
            Application_Received_in_UW__c = testReqDate,
            Type_of_Application__c = GlobalConstants.ApplicationTypeNewEnrollment,
            LOB__c = GlobalConstants.IndividualLOB,
            Bridgespan_On_Exchange__c = false,
            Bridgespan_Off_Exchange__c = false
        );
        List<OpportunityLineItem> oppLineItemsToUpsert = new List<OpportunityLineItem>();
        List<OpportunityLineItem> oppLineItemsToDelete = new List<OpportunityLineItem>();
        Applicant_Info__c subscriber = new Applicant_Info__c(
            Id = coreObjectIds.get('applicant'),
            Application__c = coreObjectIds.get('app'),
            Applicant__c = coreObjectIds.get('personContact'),
            External_ID__c = testExtId,
            Primary_Applicant__c = true,
            Applicant_Relationship__c = GlobalConstants.Subscriber,
            Last_Name__c = testLastName,
            First_Name__c = testFirstName,
            Middle_Name__c = testMiddleName,
            Sex__c = testGender,
            Birth_Date__c = testDOB,
            SSN__c = testSSN,
            Medigap_Exempt__c = testMedigapExempt,
            Medigap_Transfer_Grid__c = testTransferGrid
        );
        Prior_Coverage__c pc = new Prior_Coverage__c(
            Id = null,
            Applicant_External_ID__c = testExtId,
            ACA_Type_of_Prior_Coverage__c = testPcType,
            Insurer_Name__c = testInsurer,
            Policy_Number__c = testPolicyNumber,
            Coverage_From__c = testCoverageFrom,
            Coverage_To__c = testCoverageTo,
            Benefit_Type__c = testBenefitType
        );
        List<Applicant_Info__c> applicantsToUpsert = new List<Applicant_Info__c>{
            subscriber
        };
        List<Applicant_Info__c> applicantsToDelete = new List<Applicant_Info__c>();
        List<Prior_Coverage__c> pcToUpsert = new List<Prior_Coverage__c>{ pc };
        List<Prior_Coverage__c> pcToDelete = new List<Prior_Coverage__c>();
        List<Enrollment_Validation_Error__c> enrValErrorsToDelete = new List<Enrollment_Validation_Error__c>();
        Opportunity_Comment__c oppNote = new Opportunity_Comment__c(
            Comment__c = 'Test'
        );

        Test.startTest();
        Map<String, Object> response = CRM_ApplicationController.saveApplication(
            app,
            opp,
            oppLineItemsToUpsert,
            oppLineItemsToDelete,
            applicantsToUpsert,
            applicantsToDelete,
            pcToUpsert,
            pcToDelete,
            oppNote,
            enrValErrorsToDelete,
            testServiceArea,
            opp.AccountId,
            true
        );
        Test.stopTest();
        System.assertNotEquals(null, response);
        String appIdString = (String) response.get('recordId');
        System.assertEquals(coreObjectIds.get('app'), appIdString);

        // Confirm the Id is of the Application__c SObject type
        Id appId = Id.valueOf(appIdString);
        System.assertEquals(
            Schema.Application__c.SObjectType,
            appId.getSobjectType()
        );
        List<ACA_Paper_Application__c> acaApps = [
            SELECT
                Id,
                Application__c,
                Application__r.Opportunity__r.AccountId,
                Application__r.Opportunity__r.Account.ShippingStreet,
                Application__r.ACA_Paper_Application__c,
                Application__r.Payment_Authorization_Signature__c
            FROM ACA_Paper_Application__c
            WHERE Application__c = :appIdString
        ];
        System.assertEquals(1, acaApps.size());
        System.assertEquals(coreObjectIds.get('acaApp'), acaApps[0].Id);
        System.assertEquals(
            coreObjectIds.get('app'),
            acaApps[0].Application__c
        );
        System.assertEquals(
            coreObjectIds.get('personAccount'),
            acaApps[0].Application__r.Opportunity__r.AccountId
        );
        System.assertEquals(
            testStreet,
            acaApps[0].Application__r.Opportunity__r.Account.ShippingStreet,
            acaApps[0].Application__r.Opportunity__r.AccountId
        );
        System.assertEquals(
            'Test',
            acaApps[0].Application__r.Payment_Authorization_Signature__c
        );
        List<Applicant_Info__c> applicants = [
            SELECT
                Id,
                External_ID__c,
                Applicant__c,
                Applicant__r.LastName,
                Applicant__r.FirstName,
                Applicant__r.Middle_Name__c,
                Applicant__r.Gender__c,
                Applicant__r.DOB__c,
                Applicant__r.SSN__c,
                Applicant__r.AccountId,
                Applicant__r.Account.ShippingStreet,
                Applicant__r.Account.ShippingCity,
                Applicant__r.Account.ShippingState,
                Applicant__r.Account.ShippingPostalCode,
                Applicant__r.County__c,
                Applicant__r.Account.RecordTypeId,
                Last_Name__c,
                First_Name__c,
                Middle_Name__c,
                Sex__c,
                Birth_Date__c,
                SSN__c,
                Medigap_Exempt__c,
                Medigap_Transfer_Grid__c,
                (
                    SELECT
                        Id,
                        Applicant_External_ID__c,
                        ACA_Type_of_Prior_Coverage__c,
                        Insurer_Name__c,
                        Policy_Number__c,
                        Coverage_From__c,
                        Coverage_To__c,
                        Benefit_Type__c
                    FROM Prior_Coverages__r
                )
            FROM Applicant_Info__c
            WHERE Application__c = :appId
        ];
        System.assertEquals(1, applicants.size());
        Applicant_Info__c applicant = applicants[0];
        System.assertEquals(testLastName, applicant.Last_Name__c);
        System.assertEquals(testFirstName, applicant.First_Name__c);
        System.assertEquals(testMiddleName, applicant.Middle_Name__c);
        System.assertEquals(testGender, applicant.Sex__c);
        System.assertEquals(testDOB, applicant.Birth_Date__c);
        System.assertEquals(testSSN, applicant.SSN__c);
        System.assertEquals(testMedigapExempt, applicant.Medigap_Exempt__c);
        System.assertEquals(
            testTransferGrid,
            applicant.Medigap_Transfer_Grid__c
        );
        System.assertNotEquals(null, applicant.Applicant__c);
        Contact personContact = applicant.Applicant__r;
        System.assertEquals(testLastName, personContact.LastName);
        System.assertEquals(testFirstName, personContact.FirstName);
        System.assertEquals(testMiddleName, personContact.Middle_Name__c);
        System.assertEquals(testGender, personContact.Gender__c);
        System.assertEquals(testDOB, personContact.DOB__c);
        System.assertEquals(testSSN, personContact.SSN__c);
        System.assertEquals(
            coreObjectIds.get('personAccount'),
            personContact.AccountId
        );
        System.assertEquals(testStreet, personContact.Account.ShippingStreet);
        System.assertEquals(testCity, personContact.Account.ShippingCity);
        System.assertEquals(testState, personContact.Account.ShippingState);
        System.assertEquals(testZip, personContact.Account.ShippingPostalCode);
        System.assertEquals(testCounty, personContact.County__c);
        System.assertEquals(
            GlobalConstants.individualRT,
            personContact.Account.RecordTypeId
        );
        System.assertNotEquals(null, applicant.Prior_Coverages__r);
        System.assertEquals(1, applicant.Prior_Coverages__r.size());
        Prior_Coverage__c priorCoverage = applicant.Prior_Coverages__r[0];
        System.assertEquals(testExtId, priorCoverage.Applicant_External_ID__c);
        System.assertEquals(
            testPcType,
            priorCoverage.ACA_Type_of_Prior_Coverage__c
        );
        System.assertEquals(testInsurer, priorCoverage.Insurer_Name__c);
        System.assertEquals(testPolicyNumber, priorCoverage.Policy_Number__c);
        System.assertEquals(testCoverageFrom, priorCoverage.Coverage_From__c);
        System.assertEquals(testCoverageTo, priorCoverage.Coverage_To__c);
        System.assertEquals(testBenefitType, priorCoverage.Benefit_Type__c);
        System.assertEquals(
            1,
            [SELECT Id FROM Opportunity_Comment__c].size(),
            'Opportunity Note is not created!'
        );
    }

    @isTest
    public static void testSaveNewMedigapApplication() {
        Service_Area__c serviceAreaMedicalQuestionnaire = DatabaseHelper.getServiceAreaByExtAreaId(
            'OR'
        );
        Map<String, String> coreObjectIds = CRM_ApplicationController.createCoreObjects(
            'OR',
            GlobalConstants.MedigapLOB,
            false
        );
        System.assertNotEquals(null, coreObjectIds);
        System.assertNotEquals(0, coreObjectIds.size());
        String testStreet = '123 Main St.';
        String testCity = 'Portland';
        String testState = 'OR';
        String testZip = '97214';
        String testCounty = 'Multnomah';
        String testServiceArea = 'OR';
        String testFirstName = 'TestFirst';
        String testMiddleName = 'TestMiddle';
        String testLastName = 'TestLast';
        String testGender = 'Female';
        String testSSN = '123-45-6789';
        String testExtId = 'TEMPID8a42cd18-7ba5-483a-99c0-276b3d2e3e66';
        String testPcType = 'COBRA;Medicare';
        String testInsurer = 'Acme Insurance';
        String testPolicyNumber = 'P-012345';
        String testBenefitType = 'Medical';
        Boolean testMedigapExempt = true;
        String testTransferGrid = '0000000';

        Date testDOB = Date.newInstance(1970, 1, 1);
        Date testEffDate = Date.newInstance(2020, 2, 1);
        Date testReqDate = Date.newInstance(2020, 1, 15);
        Date testCoverageFrom = Date.newInstance(2015, 7, 15);
        Date testCoverageTo = Date.newInstance(2020, 1, 31);
        Application__c app = new Application__c(
            Id = coreObjectIds.get('app'),
            Opportunity__c = coreObjectIds.get('opp'),
            Requested_Effective_Date__c = testEffDate,
            Street_Address__c = testStreet,
            Street_City__c = testCity,
            Street_State__c = testState,
            Street_Zip__c = testZip,
            Street_County__c = testCounty,
            Is_Street_Address_Validated__c = false,
            Method_of_Payment__c = null,
            Surepay_Transaction_Day__c = null
        );
        Opportunity opp = new Opportunity(
            Id = coreObjectIds.get('opp'),
            AccountId = coreObjectIds.get('personAccount'),
            Application__c = coreObjectIds.get('app'),
            Effective_Date__c = testEffDate,
            StageName = 'App Received',
            Application_Received__c = testReqDate,
            Application_Received_in_UW__c = testReqDate,
            Type_of_Application__c = GlobalConstants.ApplicationTypeNewEnrollment,
            LOB__c = GlobalConstants.MedigapLOB,
            Bridgespan_On_Exchange__c = false,
            Bridgespan_Off_Exchange__c = false
        );
        List<OpportunityLineItem> oppLineItemsToUpsert = new List<OpportunityLineItem>();
        List<OpportunityLineItem> oppLineItemsToDelete = new List<OpportunityLineItem>();
        Applicant_Info__c subscriber = new Applicant_Info__c(
            Id = coreObjectIds.get('applicant'),
            Application__c = coreObjectIds.get('app'),
            Applicant__c = coreObjectIds.get('personContact'),
            External_ID__c = testExtId,
            Primary_Applicant__c = true,
            Applicant_Relationship__c = GlobalConstants.Subscriber,
            Last_Name__c = testLastName,
            First_Name__c = testFirstName,
            Middle_Name__c = testMiddleName,
            Sex__c = testGender,
            Birth_Date__c = testDOB,
            SSN__c = testSSN,
            Medigap_Exempt__c = testMedigapExempt,
            Medigap_Transfer_Grid__c = testTransferGrid
        );
        Prior_Coverage__c pc = new Prior_Coverage__c(
            Id = null,
            Applicant_External_ID__c = testExtId,
            ACA_Type_of_Prior_Coverage__c = testPcType,
            Insurer_Name__c = testInsurer,
            Policy_Number__c = testPolicyNumber,
            Coverage_From__c = testCoverageFrom,
            Coverage_To__c = testCoverageTo,
            Benefit_Type__c = testBenefitType
        );
        List<Applicant_Info__c> applicantsToUpsert = new List<Applicant_Info__c>{
            subscriber
        };
        List<Applicant_Info__c> applicantsToDelete = new List<Applicant_Info__c>();
        List<Prior_Coverage__c> pcToUpsert = new List<Prior_Coverage__c>{ pc };
        List<Prior_Coverage__c> pcToDelete = new List<Prior_Coverage__c>();
        List<Enrollment_Validation_Error__c> enrValErrorsToDelete = new List<Enrollment_Validation_Error__c>();
        Opportunity_Comment__c oppNote = new Opportunity_Comment__c(
            Comment__c = 'Test'
        );

        Test.startTest();
        Map<String, Object> response = CRM_ApplicationController.saveApplication(
            app,
            opp,
            oppLineItemsToUpsert,
            oppLineItemsToDelete,
            applicantsToUpsert,
            applicantsToDelete,
            pcToUpsert,
            pcToDelete,
            oppNote,
            enrValErrorsToDelete,
            testServiceArea,
            opp.AccountId,
            true
        );
        Test.stopTest();
        System.assertNotEquals(null, response);
        String appIdString = (String) response.get('recordId');
        System.assertEquals(coreObjectIds.get('app'), appIdString);

        // Confirm the Id is of the Application__c SObject type
        Id appId = Id.valueOf(appIdString);
        System.assertEquals(
            Schema.Application__c.SObjectType,
            appId.getSobjectType()
        );
        List<WA_Paper_Application__c> acaApps = [
            SELECT
                Id,
                Application__c,
                Application__r.Opportunity__r.AccountId,
                Application__r.Opportunity__r.Account.ShippingStreet,
                Application__r.ACA_Paper_Application__c
            FROM WA_Paper_Application__c
            WHERE Application__c = :appIdString
        ];

        System.assertEquals(1, acaApps.size());
        System.assertEquals(coreObjectIds.get('nonAcaApp'), acaApps[0].Id);
        System.assertEquals(
            coreObjectIds.get('app'),
            acaApps[0].Application__c
        );
        System.assertEquals(
            coreObjectIds.get('personAccount'),
            acaApps[0].Application__r.Opportunity__r.AccountId
        );
        System.assertEquals(
            testStreet,
            acaApps[0].Application__r.Opportunity__r.Account.ShippingStreet,
            acaApps[0].Application__r.Opportunity__r.AccountId
        );

        List<Applicant_Info__c> applicants = [
            SELECT
                Id,
                External_ID__c,
                Applicant__c,
                Applicant__r.LastName,
                Applicant__r.FirstName,
                Applicant__r.Middle_Name__c,
                Applicant__r.Gender__c,
                Applicant__r.DOB__c,
                Applicant__r.SSN__c,
                Applicant__r.AccountId,
                Applicant__r.Account.ShippingStreet,
                Applicant__r.Account.ShippingCity,
                Applicant__r.Account.ShippingState,
                Applicant__r.Account.ShippingPostalCode,
                Applicant__r.County__c,
                Applicant__r.Account.RecordTypeId,
                Last_Name__c,
                First_Name__c,
                Middle_Name__c,
                Sex__c,
                Birth_Date__c,
                SSN__c,
                Medigap_Exempt__c,
                Medigap_Transfer_Grid__c,
                Medical_Questionnaire__c,
                (
                    SELECT
                        Id,
                        Applicant_External_ID__c,
                        ACA_Type_of_Prior_Coverage__c,
                        Insurer_Name__c,
                        Policy_Number__c,
                        Coverage_From__c,
                        Coverage_To__c,
                        Benefit_Type__c
                    FROM Prior_Coverages__r
                )
            FROM Applicant_Info__c
            WHERE Application__c = :appId
        ];
        System.assertEquals(1, applicants.size());
        Applicant_Info__c applicant = applicants[0];
        System.assertEquals(testLastName, applicant.Last_Name__c);
        System.assertEquals(testFirstName, applicant.First_Name__c);
        System.assertEquals(testMiddleName, applicant.Middle_Name__c);
        System.assertEquals(testGender, applicant.Sex__c);
        System.assertEquals(testDOB, applicant.Birth_Date__c);
        System.assertEquals(testSSN, applicant.SSN__c);
        System.assertEquals(testMedigapExempt, applicant.Medigap_Exempt__c);
        System.assertEquals(
            testTransferGrid,
            applicant.Medigap_Transfer_Grid__c
        );
        System.assertNotEquals(null, applicant.Applicant__c);
        System.assertEquals(
            serviceAreaMedicalQuestionnaire.Medigap_Questionnaire__c,
            applicant.Medical_Questionnaire__c
        );
        Contact personContact = applicant.Applicant__r;
        System.assertEquals(testLastName, personContact.LastName);
        System.assertEquals(testFirstName, personContact.FirstName);
        System.assertEquals(testMiddleName, personContact.Middle_Name__c);
        System.assertEquals(testGender, personContact.Gender__c);
        System.assertEquals(testDOB, personContact.DOB__c);
        System.assertEquals(testSSN, personContact.SSN__c);
        System.assertEquals(
            coreObjectIds.get('personAccount'),
            personContact.AccountId
        );
        System.assertEquals(testStreet, personContact.Account.ShippingStreet);
        System.assertEquals(testCity, personContact.Account.ShippingCity);
        System.assertEquals(testState, personContact.Account.ShippingState);
        System.assertEquals(testZip, personContact.Account.ShippingPostalCode);
        System.assertEquals(testCounty, personContact.County__c);
        System.assertEquals(
            GlobalConstants.individualRT,
            personContact.Account.RecordTypeId
        );
        System.assertNotEquals(null, applicant.Prior_Coverages__r);
        System.assertEquals(1, applicant.Prior_Coverages__r.size());
        Prior_Coverage__c priorCoverage = applicant.Prior_Coverages__r[0];
        System.assertEquals(testExtId, priorCoverage.Applicant_External_ID__c);
        System.assertEquals(
            testPcType,
            priorCoverage.ACA_Type_of_Prior_Coverage__c
        );
        System.assertEquals(testInsurer, priorCoverage.Insurer_Name__c);
        System.assertEquals(testPolicyNumber, priorCoverage.Policy_Number__c);
        System.assertEquals(testCoverageFrom, priorCoverage.Coverage_From__c);
        System.assertEquals(testCoverageTo, priorCoverage.Coverage_To__c);
        System.assertEquals(testBenefitType, priorCoverage.Benefit_Type__c);
        System.assertEquals(
            1,
            [SELECT Id FROM Opportunity_Comment__c].size(),
            'Opportunity Note is not created!'
        );
        Application__c updatedApp = [
            SELECT Medical_Questionnaire__c
            FROM Application__c
            WHERE Id = :coreObjectIds.get('app')
            LIMIT 1
        ];
        System.assertEquals(
            serviceAreaMedicalQuestionnaire.Medigap_Questionnaire__c,
            updatedApp.Medical_Questionnaire__c
        );
    }

    @isTest
    public static void testSaveExistingApplication() {
        List<Application__c> testApps = [
            SELECT
                Id,
                Opportunity__c,
                ACA_Paper_Application__c,
                WA_Paper_Application__c,
                Requested_Effective_Date__c,
                Opportunity__r.Id,
                Opportunity__r.AccountId,
                Opportunity__r.Name,
                Opportunity__r.Application_Received__c,
                Opportunity__r.Type_of_Application__c,
                Opportunity__r.LOB__c,
                Opportunity__r.RecordTypeId,
                Opportunity__r.StageName,
                Opportunity__r.Service_Area__c,
                Opportunity__r.CloseDate,
                Opportunity__r.Created_Through_WA_Paper_App__c,
                Home_Phone__c,
                Mailing_Address__c,
                Mailing_City__c,
                Mailing_State__c,
                Mailing_Zip__c,
                Mailing_County__c,
                Street_Address__c,
                Street_City__c,
                Street_State__c,
                Street_Zip__c,
                Street_County__c,
                Billing_Address__c,
                Billing_City__c,
                Billing_State__c,
                Billing_Zip__c,
                Billing_County__c,
                E_mail_Address__c,
                Work_Phone__c,
                Mobile_Phone__c,
                Method_of_Payment__c,
                Surepay_Transaction_Day__c,
                Medical_Questionnaire__c,
                (
                    SELECT
                        Id,
                        External_ID__c,
                        Applicant_Relationship__c,
                        Applicant_Account_ID__c,
                        Application__c,
                        First_Name__c,
                        Last_Name__c,
                        Middle_Name__c,
                        SSN__c,
                        Sex__c,
                        Birth_Date__c,
                        Primary_Applicant__c,
                        Applicant__c
                    FROM Applicants_Info__r
                )
            FROM Application__c
        ];
        System.assertEquals(
            1,
            testApps.size(),
            'Expect @TestSetup to have created an app'
        );
        Application__c testApp = testApps[0];
        List<Applicant_Info__c> testApplicants = testApp.Applicants_Info__r;
        System.assertEquals(
            3,
            testApplicants.size(),
            'Expect @TestSetup-created app to have 3 applicants'
        );

        List<Prior_Coverage__c> testPcs = [
            SELECT
                Id,
                Applicant_External_ID__c,
                ACA_Type_of_Prior_Coverage__c,
                Insurer_Name__c,
                Policy_Number__c,
                Coverage_From__c,
                Coverage_To__c,
                Benefit_Type__c
            FROM Prior_Coverage__c
        ];
        System.assertEquals(
            3,
            testPcs.size(),
            'Expect each @TestSetup-created applicant to have a prior coverage'
        );

        List<OpportunityLineItem> testOppLineItems = [
            SELECT Id, PricebookEntryId
            FROM OpportunityLineItem
            WHERE OpportunityId = :testApp.Opportunity__c
        ];
        System.assertEquals(
            1,
            testOppLineItems.size(),
            'Expect @TestSetup-created app to have 1 opp line item'
        );

        List<Enrollment_Validation_Error__c> enrollmentErrors = [
            SELECT Id, Application__c
            FROM Enrollment_Validation_Error__c
            WHERE Application__c = :testApp.Id
        ];
        System.assertEquals(
            1,
            enrollmentErrors.size(),
            'Expect @TestSetup-created app to have 1 enrollment error'
        );

        String testServiceArea = 'OR';
        String testFirstName = 'MyNewFirstName';
        String testMiddleName = 'MyNewMiddleName';
        Date testDOB = Date.newInstance(1971, 2, 3);
        Date testReqDate = Date.newInstance(2020, 1, 15);

        testApp.Requested_Effective_Date__c = testReqDate;
        testApp.Opportunity__r.Application_Received__c = testReqDate;
        // Test the defaulting of Surepay_Transaction_Day__c
        testApp.Method_of_Payment__c = GlobalConstants.MethodOfPaymentEFT;

        List<OpportunityLineItem> oppLineItemsToUpsert = new List<OpportunityLineItem>();
        List<OpportunityLineItem> oppLineItemsToDelete = new List<OpportunityLineItem>{
            testOppLineItems[0]
        };
        List<Applicant_Info__c> applicantsToUpsert = new List<Applicant_Info__c>();
        List<Applicant_Info__c> applicantsToDelete = new List<Applicant_Info__c>();
        List<Prior_Coverage__c> pcToUpsert = new List<Prior_Coverage__c>();
        List<Prior_Coverage__c> pcToDelete = new List<Prior_Coverage__c>();
        for (Applicant_Info__c a : testApplicants) {
            if (a.Applicant_Relationship__c == GlobalConstants.Subscriber) {
                a.Primary_Applicant__c = true;
                a.First_Name__c = testFirstName;
                a.Middle_Name__c = testMiddleName;
                a.Birth_Date__c = testDOB;
                applicantsToUpsert.add(a);
                for (Prior_Coverage__c pc : testPcs) {
                    if (pc.Applicant_External_ID__c == a.External_ID__c) {
                        pcToUpsert.add(pc);
                    }
                }
            } else if (applicantsToDelete.size() == 0) {
                applicantsToDelete.add(a);
                for (Prior_Coverage__c pc : testPcs) {
                    if (pc.Applicant_External_ID__c == a.External_ID__c) {
                        pcToDelete.add(pc);
                    }
                }
            } else {
                applicantsToUpsert.add(a);
                for (Prior_Coverage__c pc : testPcs) {
                    if (pc.Applicant_External_ID__c == a.External_ID__c) {
                        pcToUpsert.add(pc);
                    }
                }
            }
        }
        System.assertEquals(1, pcToDelete.size(), pcToDelete);

        // Add new applicant
        String newApplicantExtId = 'TEMPID00789';
        Applicant_Info__c newApplicant = new Applicant_Info__c(
            Application__c = testApp.Id,
            External_ID__c = newApplicantExtId,
            Applicant_Relationship__c = 'Child',
            First_Name__c = 'A. New',
            Last_Name__c = 'Dependent',
            Sex__c = 'Female',
            Birth_Date__c = Date.newInstance(2010, 1, 1),
            Primary_Applicant__c = false
        );
        applicantsToUpsert.add(newApplicant);

        // Add new prior coverage
        Prior_Coverage__c newPc = new Prior_Coverage__c(
            Applicant_External_ID__c = newApplicantExtId,
            ACA_Type_of_Prior_Coverage__c = 'COBRA',
            Insurer_Name__c = 'Acme Insurance, Inc.',
            Policy_Number__c = 'P-8675309',
            Coverage_From__c = Date.newInstance(2005, 1, 1),
            Coverage_To__c = Date.newInstance(2020, 1, 31),
            Benefit_Type__c = 'Medical'
        );
        pcToUpsert.add(newPc);

        Product_Class__c productClass = [
            SELECT Id, Description__c, Product__c
            FROM Product_Class__c
            WHERE
                Service_Area__r.ExtAreaID__c = 'OR'
                AND Product_Filter__c = NULL
            LIMIT 1
        ];
        PricebookEntry pbe = [
            SELECT Id, UnitPrice
            FROM PricebookEntry
            WHERE Product2Id = :productClass.Product__c
            LIMIT 1
        ];

        oppLineItemsToUpsert.add(
            new OpportunityLineItem(
                OpportunityId = testApp.Opportunity__c,
                Applied_For__c = true,
                Quantity = 1,
                Product_Class__c = productClass.Id,
                Description = productClass.Description__c,
                PricebookEntryId = pbe.Id,
                UnitPrice = pbe.UnitPrice,
                ServiceDate = Date.today()
            )
        );

        System.assertEquals(
            3,
            applicantsToUpsert.size(),
            '2 applicants were updated; 1 was added'
        );
        System.assertEquals(
            1,
            applicantsToDelete.size(),
            '1 applicant should be in the delete list'
        );
        System.assertEquals(
            3,
            pcToUpsert.size(),
            'A prior coverage for each remaining applicant should be in the upsert list'
        );
        System.assertEquals(
            1,
            pcToDelete.size(),
            'The deleted applicant\'s prior coverage should also be up for deletion'
        );
        //
        System.assertEquals(1, oppLineItemsToUpsert.size());
        System.assertEquals(1, oppLineItemsToDelete.size());

        Test.startTest();
        Opportunity_Comment__c oppNote = new Opportunity_Comment__c(
            Comment__c = 'Test'
        );
        Map<String, Object> response = CRM_ApplicationController.saveApplication(
            testApp,
            testApp.Opportunity__r,
            oppLineItemsToUpsert,
            oppLineItemsToDelete,
            applicantsToUpsert,
            applicantsToDelete,
            pcToUpsert,
            pcToDelete,
            oppNote,
            enrollmentErrors,
            testServiceArea,
            testApp.Opportunity__r.AccountId,
            false
        );

        System.assertNotEquals(null, response);
        String appIdString = (String) response.get('recordId');
        System.assertNotEquals(null, appIdString);
        // Confirm the Id is of the Application__c SObject type
        Id appId = Id.valueOf(appIdString);
        System.assertEquals(
            Schema.Application__c.SObjectType,
            appId.getSobjectType()
        );
        List<Applicant_Info__c> applicants = [
            SELECT
                Id,
                External_ID__c,
                Applicant_Relationship__c,
                Applicant__c,
                Applicant__r.FirstName,
                Applicant__r.Middle_Name__c,
                Applicant__r.DOB__c,
                First_Name__c,
                Middle_Name__c,
                Last_Name__c,
                Birth_Date__c,
                Primary_Applicant__c,
                Application__c,
                Application__r.Requested_Effective_Date__c,
                Application__r.Surepay_Transaction_Day__c,
                Opportunity__c,
                Opportunity__r.Application_Received__c,
                (
                    SELECT
                        Id,
                        ACA_Type_of_Prior_Coverage__c,
                        Insurer_Name__c,
                        Policy_Number__c,
                        Coverage_From__c,
                        Coverage_To__c,
                        Benefit_Type__c
                    FROM Prior_Coverages__r
                )
            FROM Applicant_Info__c
            WHERE Application__c = :appId
        ];

        // After deleting one dependent and adding a new one, there should be 3
        System.assertEquals(3, applicants.size(), 'applicants: ' + applicants);
        List<Id> applicantIds = new List<Id>();
        Integer primaryApplicantsCount = 0;
        Integer newApplicantsCount = 0;
        for (Applicant_Info__c a : applicants) {
            applicantIds.add(a.Id);
            System.assertNotEquals(null, a.Applicant__c, a);
            // Make sure the primary applicant was updated
            if (a.Primary_Applicant__c) {
                System.assertEquals(a.First_Name__c, testFirstName, a);
                System.assertEquals(a.Middle_Name__c, testMiddleName, a);
                System.assertEquals(a.Birth_Date__c, testDOB, a);
                Contact personContact = a.Applicant__r;
                System.assertEquals(personContact.FirstName, testFirstName, a);
                System.assertEquals(
                    personContact.Middle_Name__c,
                    testMiddleName,
                    a
                );
                System.assertEquals(personContact.DOB__c, testDOB, a);
                primaryApplicantsCount++;
            }
            // Make sure the new applicant and their new prior coverage were inserted
            if (a.External_ID__c == newApplicantExtId) {
                System.assertEquals(
                    newApplicant.First_Name__c,
                    a.First_Name__c,
                    a
                );
                System.assertEquals(
                    newApplicant.Last_Name__c,
                    a.Last_Name__c,
                    a
                );
                System.assertEquals(
                    newApplicant.Birth_Date__c,
                    a.Birth_Date__c,
                    a
                );
                System.assertEquals(
                    newApplicant.Applicant_Relationship__c,
                    a.Applicant_Relationship__c,
                    a
                );
                System.assertEquals(1, a.Prior_Coverages__r.size());
                Prior_Coverage__c pc = a.Prior_Coverages__r[0];
                System.assertEquals(
                    newPc.ACA_Type_of_Prior_Coverage__c,
                    pc.ACA_Type_of_Prior_Coverage__c,
                    pc
                );
                System.assertEquals(
                    newPc.Insurer_Name__c,
                    pc.Insurer_Name__c,
                    pc
                );
                System.assertEquals(
                    newPc.Policy_Number__c,
                    pc.Policy_Number__c,
                    pc
                );
                System.assertEquals(
                    newPc.Coverage_From__c,
                    pc.Coverage_From__c,
                    pc
                );
                System.assertEquals(
                    newPc.Coverage_To__c,
                    pc.Coverage_To__c,
                    pc
                );
                System.assertEquals(
                    newPc.Benefit_Type__c,
                    pc.Benefit_Type__c,
                    pc
                );
                newApplicantsCount++;
            }
            System.assertEquals(
                testReqDate,
                a.Application__r.Requested_Effective_Date__c
            );
            // Method_of_Payment__c was set to EFT; expect
            // Surepay_Transaction_Day__c to be set
            System.assertEquals(
                '5',
                a.Application__r.Surepay_Transaction_Day__c
            );
            System.assertNotEquals(null, a.Opportunity__c);
            System.assertEquals(
                testReqDate,
                a.Opportunity__r.Application_Received__c
            );
        }
        System.assertEquals(1, primaryApplicantsCount);
        System.assertEquals(1, newApplicantsCount);
        // Assert that the intended applicant was deleted
        System.assert(!applicantIds.contains(applicantsToDelete[0].Id));

        List<OpportunityLineItem> oppLineItems = [
            SELECT Id, PricebookEntryId, Product_Class__c, Description
            FROM OpportunityLineItem
            WHERE OpportunityId = :applicants[0].Opportunity__c
        ];
        System.assertEquals(1, oppLineItems.size());
        System.assertEquals(
            oppLineItemsToUpsert[0].PricebookEntryId,
            oppLineItems[0].PricebookEntryId
        );
        System.assertEquals(
            oppLineItemsToUpsert[0].Product_Class__c,
            oppLineItems[0].Product_Class__c
        );
        System.assertEquals(
            oppLineItemsToUpsert[0].Description,
            oppLineItems[0].Description
        );
        System.assertEquals(
            1,
            [SELECT Id FROM Opportunity_Comment__c].size(),
            'Opportunity Note is not created!'
        );
        Test.stopTest();
    }

    @isTest
    public static void testSaveMergableApplication() {
        Map<String, String> coreObjectIds = CRM_ApplicationController.createCoreObjects(
            'OR',
            GlobalConstants.IndividualLOB,
            false
        );
        Account testMasterAccount = [
            SELECT Id, FirstName, LastName, DOB__pc, SSN__pc, Gender__pc
            FROM Account
            LIMIT 1
        ];

        // Account Bug either exists in TestSetup
        // or inside our system for setting Gender and DOB on insert
        testMasterAccount.Gender__pc = 'Male';
        testMasterAccount.DOB__pc = Date.today().addYears(-50);
        // This address will be overwritten by the save operation
        testMasterAccount.ShippingStreet = '8888 East West St';
        testMasterAccount.ShippingCity = 'Gresham';
        testMasterAccount.ShippingPostalCode = '97024';
        // These values should not be overwritten, since the corresponding App Entry values will be blank
        testMasterAccount.Home_Phone__pc = '(503) 555-0001';
        testMasterAccount.Phone = '(503) 555-0002';
        testMasterAccount.PersonEmail = 'test@test.me';
        // This value will not be overwritten, since App Entry doesn't use this field
        testMasterAccount.Product_Interest__c = 'Medical';
        update testMasterAccount;

        System.assertNotEquals(null, coreObjectIds);
        System.assertNotEquals(0, coreObjectIds.size());
        String testStreet = '123 Main St.';
        String testCity = 'Portland';
        String testState = 'OR';
        String testZip = '97214';
        String testCounty = 'Multnomah';
        String testStreet2 = 'PO Box 456';
        String testCity2 = 'Beaverton';
        String testState2 = 'OR';
        String testZip2 = '97005';
        String testCounty2 = 'Washington';
        String testPhone = '(503) 555-1234';
        String testServiceArea = 'OR';
        String testFirstName = testMasterAccount.FirstName;
        String testMiddleName = 'TestMiddle';
        String testLastName = testMasterAccount.LastName;
        String testGender = testMasterAccount.Gender__pc;
        String testSSN = testMasterAccount.SSN__pc;
        String testExtId = 'TEMPID8a42cd18-7ba5-483a-99c0-276b3d2e3e66';
        Boolean testMedigapExempt = true;
        String testTransferGrid = '0000000';

        Date testDOB = testMasterAccount.DOB__pc;
        Date testEffDate = Date.newInstance(2020, 2, 1);
        Date testReqDate = Date.newInstance(2020, 1, 15);
        Application__c app = new Application__c(
            Id = coreObjectIds.get('app'),
            Opportunity__c = coreObjectIds.get('opp'),
            Requested_Effective_Date__c = testEffDate,
            Street_Address__c = testStreet,
            Street_City__c = testCity,
            Street_State__c = testState,
            Street_Zip__c = testZip,
            Street_County__c = testCounty,
            Mailing_Address__c = testStreet2,
            Mailing_City__c = testCity2,
            Mailing_State__c = testState2,
            Mailing_Zip__c = testZip2,
            Mailing_County__c = testCounty2,
            Billing_Same_as_Mailing__c = true,
            Billing_Address__c = testStreet2,
            Billing_City__c = testCity2,
            Billing_State__c = testState2,
            Billing_Zip__c = testZip2,
            Billing_County__c = testCounty2,
            Home_Phone__c = null, // blank should not overwrite master account value
            Work_Phone__c = null, // blank should not overwrite master account value
            Mobile_Phone__c = testPhone,
            E_mail_Address__c = '', // blank should not overwrite master account value
            Is_Street_Address_Validated__c = false,
            Method_of_Payment__c = null,
            Surepay_Transaction_Day__c = null
        );
        Opportunity opp = new Opportunity(
            Id = coreObjectIds.get('opp'),
            AccountId = coreObjectIds.get('personAccount'),
            Application__c = coreObjectIds.get('app'),
            Effective_Date__c = testEffDate,
            Application_Received__c = testReqDate,
            Application_Received_in_UW__c = testReqDate,
            Type_of_Application__c = GlobalConstants.ApplicationTypeNewEnrollment,
            LOB__c = GlobalConstants.IndividualLOB,
            Bridgespan_On_Exchange__c = false,
            Bridgespan_Off_Exchange__c = false
        );
        Applicant_Info__c subscriber = new Applicant_Info__c(
            Id = coreObjectIds.get('applicant'),
            Application__c = coreObjectIds.get('app'),
            Applicant__c = coreObjectIds.get('personContact'),
            External_ID__c = testExtId,
            Primary_Applicant__c = true,
            Applicant_Relationship__c = GlobalConstants.Subscriber,
            Last_Name__c = testLastName,
            First_Name__c = testFirstName,
            Middle_Name__c = testMiddleName,
            Sex__c = testGender,
            Birth_Date__c = testDOB,
            SSN__c = testSSN,
            Medigap_Exempt__c = testMedigapExempt,
            Medigap_Transfer_Grid__c = testTransferGrid
        );
        List<Applicant_Info__c> applicantsToUpsert = new List<Applicant_Info__c>{
            subscriber
        };
        User testUser = TestRecordUtility.createTestUser(1)[0];

        Test.startTest();
        System.runAs(testUser) {
            Map<String, Object> response = CRM_ApplicationController.saveApplication(
                app,
                opp,
                null,
                null,
                applicantsToUpsert,
                null,
                null,
                null,
                null,
                null,
                testServiceArea,
                opp.AccountId,
                true
            );
        }
        Test.stopTest();

        List<Account> accountsAfterSaveWithMasterData = [
            SELECT
                Id,
                FirstName,
                LastName,
                DOB__pc,
                SSN__pc,
                Gender__pc,
                ShippingStreet,
                ShippingCity,
                ShippingPostalCode,
                PersonMailingStreet,
                PersonMailingCity,
                PersonMailingPostalCode,
                Mailing_County__pc,
                BillingStreet,
                BillingCity,
                BillingPostalCode,
                Billing_County__c,
                Phone,
                PersonMobilePhone,
                Home_Phone__pc,
                PersonEmail,
                Product_Interest__c,
                LastModifiedById
            FROM Account
            WHERE
                FirstName = :testMasterAccount.FirstName
                AND LastName = :testMasterAccount.LastName
                AND DOB__pc = :testMasterAccount.DOB__pc
                AND SSN__pc = :testMasterAccount.SSN__pc
                AND Gender__pc = :testMasterAccount.Gender__pc
        ];
        System.assertEquals(
            1,
            accountsAfterSaveWithMasterData.size(),
            'Number of Accounts with same data increased. Duplicate not merged!'
        );
        Account savedAccount = accountsAfterSaveWithMasterData[0];
        System.assertEquals(
            testMasterAccount.Id,
            savedAccount.Id,
            'The surviving record should retain the Id of the master account'
        );
        // The master account should have been updated in the save operation
        System.assertEquals(testUser.Id, savedAccount.LastModifiedById);
        // Master account address fields should have been overwritten with the newly saved data
        System.assertEquals(app.Street_Address__c, savedAccount.ShippingStreet);
        System.assertEquals(app.Street_City__c, savedAccount.ShippingCity);
        System.assertEquals(app.Street_Zip__c, savedAccount.ShippingPostalCode);
        System.assertEquals(
            app.Mailing_Address__c,
            savedAccount.PersonMailingStreet
        );
        System.assertEquals(
            app.Mailing_City__c,
            savedAccount.PersonMailingCity
        );
        System.assertEquals(
            app.Mailing_Zip__c,
            savedAccount.PersonMailingPostalCode
        );
        System.assertEquals(
            app.Mailing_County__c,
            savedAccount.Mailing_County__pc
        );
        System.assertEquals(app.Billing_Address__c, savedAccount.BillingStreet);
        System.assertEquals(app.Billing_City__c, savedAccount.BillingCity);
        System.assertEquals(app.Billing_Zip__c, savedAccount.BillingPostalCode);
        System.assertEquals(
            app.Billing_County__c,
            savedAccount.Billing_County__c
        );
        System.assertEquals(
            app.Mobile_Phone__c,
            savedAccount.PersonMobilePhone
        );
        // Make sure pre-existing values not updated in the save are still present on the master record, not overwritten
        System.assertEquals(testMasterAccount.Phone, savedAccount.Phone);
        System.assertEquals(
            testMasterAccount.Home_Phone__pc,
            savedAccount.Home_Phone__pc
        );
        System.assertEquals(
            testMasterAccount.PersonEmail,
            savedAccount.PersonEmail
        );
        System.assertEquals(
            testMasterAccount.Product_Interest__c,
            savedAccount.Product_Interest__c
        );
    }
}
