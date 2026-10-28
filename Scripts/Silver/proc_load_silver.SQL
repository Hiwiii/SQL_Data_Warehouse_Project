
/*
===============================================================================
Stored Procedure: silver.load_silver
===============================================================================
Purpose:
    Loads cleaned and transformed data from the Bronze layer into the
    Silver layer of the Data Warehouse.

    This procedure performs:
    - Full loading using TRUNCATE and INSERT
    - Data cleansing and standardization
    - Duplicate removal for CRM customers
    - Handling of missing and invalid values
    - Data type conversions
    - Calculation of product end dates
    - Execution time monitoring
    - Transaction management and error handling

Source: Bronze Layer
Target: Silver Layer

Usage:
    EXEC silver.load_silver;
===============================================================================
*/


CREATE OR ALTER PROCEDURE silver.load_silver
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @batch_start_time DATETIME2,
        @batch_end_time   DATETIME2,
        @start_time       DATETIME2,
        @end_time         DATETIME2;

    BEGIN TRY

        SET @batch_start_time = SYSDATETIME();

        PRINT '========================================';
        PRINT 'Loading Silver Layer';
        PRINT '========================================';

        BEGIN TRANSACTION;

        -- =========================================================
        -- 1. CRM CUSTOMER INFORMATION
        -- =========================================================

        SET @start_time = SYSDATETIME();

        PRINT '>> Truncating Table: silver.crm_cust_info';

        TRUNCATE TABLE silver.crm_cust_info;

        PRINT '>> Inserting Data Into: silver.crm_cust_info';

        ;WITH ranked_customers AS (
            SELECT
                *,
                ROW_NUMBER() OVER (
                    PARTITION BY cst_id
                    ORDER BY cst_create_date DESC
                ) AS flag_last
            FROM bronze.crm_cust_info
            WHERE cst_id IS NOT NULL
        )
        INSERT INTO silver.crm_cust_info (
            cst_id,
            cst_key,
            cst_firstname,
            cst_lastname,
            cst_marital_status,
            cst_gndr,
            cst_create_date
        )
        SELECT
            cst_id,
            cst_key,
            TRIM(cst_firstname),
            TRIM(cst_lastname),

            CASE
                WHEN UPPER(TRIM(cst_marital_status)) = 'S'
                    THEN 'Single'
                WHEN UPPER(TRIM(cst_marital_status)) = 'M'
                    THEN 'Married'
                ELSE 'n/a'
            END,

            CASE
                WHEN UPPER(TRIM(cst_gndr)) = 'F'
                    THEN 'Female'
                WHEN UPPER(TRIM(cst_gndr)) = 'M'
                    THEN 'Male'
                ELSE 'n/a'
            END,

            cst_create_date

        FROM ranked_customers
        WHERE flag_last = 1;

        SET @end_time = SYSDATETIME();

        PRINT '>> CRM Customer Information Loaded';
        PRINT '>> Load Duration: ' +
            CAST(
                DATEDIFF_BIG(MILLISECOND, @start_time, @end_time)
                / 1000.0 AS VARCHAR(30)
            ) + ' seconds';


        -- =========================================================
        -- 2. CRM PRODUCT INFORMATION
        -- =========================================================

        SET @start_time = SYSDATETIME();

        PRINT '>> Truncating Table: silver.crm_prd_info';

        TRUNCATE TABLE silver.crm_prd_info;

        PRINT '>> Inserting Data Into: silver.crm_prd_info';

        INSERT INTO silver.crm_prd_info (
            prd_id,
            cat_id,
            prd_key,
            prd_nm,
            prd_cost,
            prd_line,
            prd_start_dt,
            prd_end_dt
        )
        SELECT
            prd_id,

            REPLACE(
                SUBSTRING(prd_key, 1, 5),
                '-', '_'
            ) AS cat_id,

            SUBSTRING(
                prd_key, 7, LEN(prd_key)
            ) AS prd_key,

            prd_nm,

            ISNULL(prd_cost, 0) AS prd_cost,

            CASE UPPER(TRIM(prd_line))
                WHEN 'M' THEN 'Mountain'
                WHEN 'R' THEN 'Road'
                WHEN 'S' THEN 'Other Sales'
                WHEN 'T' THEN 'Touring'
                ELSE 'n/a'
            END AS prd_line,

            CAST(prd_start_dt AS DATE) AS prd_start_dt,

            CAST(
                DATEADD(
                    DAY, -1,
                    LEAD(prd_start_dt) OVER (
                        PARTITION BY prd_key
                        ORDER BY prd_start_dt
                    )
                ) AS DATE
            ) AS prd_end_dt

        FROM bronze.crm_prd_info;

        SET @end_time = SYSDATETIME();

        PRINT '>> CRM Product Information Loaded';
        PRINT '>> Load Duration: ' +
            CAST(
                DATEDIFF_BIG(MILLISECOND, @start_time, @end_time)
                / 1000.0 AS VARCHAR(30)
            ) + ' seconds';


        -- =========================================================
        -- 3. CRM SALES DETAILS
        -- =========================================================

        SET @start_time = SYSDATETIME();

        PRINT '>> Truncating Table: silver.crm_sales_details';

        TRUNCATE TABLE silver.crm_sales_details;

        PRINT '>> Inserting Data Into: silver.crm_sales_details';

        INSERT INTO silver.crm_sales_details (
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            sls_order_dt,
            sls_ship_dt,
            sls_due_dt,
            sls_sales,
            sls_quantity,
            sls_price
        )
        SELECT
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,

            CASE
                WHEN sls_order_dt = 0
                  OR LEN(CAST(sls_order_dt AS VARCHAR(20))) != 8
                    THEN NULL
                ELSE TRY_CONVERT(
                    DATE,
                    CAST(sls_order_dt AS VARCHAR(20)),
                    112
                )
            END AS sls_order_dt,

            CASE
                WHEN sls_ship_dt = 0
                  OR LEN(CAST(sls_ship_dt AS VARCHAR(20))) != 8
                    THEN NULL
                ELSE TRY_CONVERT(
                    DATE,
                    CAST(sls_ship_dt AS VARCHAR(20)),
                    112
                )
            END AS sls_ship_dt,

            CASE
                WHEN sls_due_dt = 0
                  OR LEN(CAST(sls_due_dt AS VARCHAR(20))) != 8
                    THEN NULL
                ELSE TRY_CONVERT(
                    DATE,
                    CAST(sls_due_dt AS VARCHAR(20)),
                    112
                )
            END AS sls_due_dt,

            CASE
                WHEN sls_sales IS NULL
                  OR sls_sales <= 0
                  OR sls_sales != sls_quantity * ABS(sls_price)
                    THEN sls_quantity * ABS(sls_price)
                ELSE sls_sales
            END AS sls_sales,

            sls_quantity,

            CASE
                WHEN sls_price IS NULL OR sls_price <= 0
                    THEN sls_sales / NULLIF(sls_quantity, 0)
                ELSE sls_price
            END AS sls_price

        FROM bronze.crm_sales_details;

        SET @end_time = SYSDATETIME();

        PRINT '>> CRM Sales Details Loaded';
        PRINT '>> Load Duration: ' +
            CAST(
                DATEDIFF_BIG(MILLISECOND, @start_time, @end_time)
                / 1000.0 AS VARCHAR(30)
            ) + ' seconds';


        -- =========================================================
        -- 4. ERP CUSTOMER INFORMATION
        -- =========================================================

        SET @start_time = SYSDATETIME();

        PRINT '>> Truncating Table: silver.erp_cust_az12';

        TRUNCATE TABLE silver.erp_cust_az12;

        PRINT '>> Inserting Data Into: silver.erp_cust_az12';

        ;WITH cleaned_customers AS (
            SELECT
                cid,
                bdate,
                UPPER(
                    TRIM(
                        REPLACE(
                            REPLACE(gen, CHAR(13), ''),
                            CHAR(10), ''
                        )
                    )
                ) AS clean_gen
            FROM bronze.erp_cust_az12
        )
        INSERT INTO silver.erp_cust_az12 (
            cid,
            bdate,
            gen
        )
        SELECT
            CASE
                WHEN cid LIKE 'NAS%'
                    THEN SUBSTRING(cid, 4, LEN(cid))
                ELSE cid
            END AS cid,

            CASE
                WHEN bdate > GETDATE() THEN NULL
                ELSE bdate
            END AS bdate,

            CASE
                WHEN clean_gen IN ('F', 'FEMALE')
                    THEN 'Female'
                WHEN clean_gen IN ('M', 'MALE')
                    THEN 'Male'
                ELSE 'n/a'
            END AS gen

        FROM cleaned_customers;

        SET @end_time = SYSDATETIME();

        PRINT '>> ERP Customer Information Loaded';
        PRINT '>> Load Duration: ' +
            CAST(
                DATEDIFF_BIG(MILLISECOND, @start_time, @end_time)
                / 1000.0 AS VARCHAR(30)
            ) + ' seconds';


        -- =========================================================
        -- 5. ERP LOCATION INFORMATION
        -- =========================================================

        SET @start_time = SYSDATETIME();

        PRINT '>> Truncating Table: silver.erp_loc_a101';

        TRUNCATE TABLE silver.erp_loc_a101;

        PRINT '>> Inserting Data Into: silver.erp_loc_a101';

        ;WITH cleaned_locations AS (
            SELECT
                REPLACE(cid, '-', '') AS cid,

                UPPER(
                    TRIM(
                        REPLACE(
                            REPLACE(cntry, CHAR(13), ''),
                            CHAR(10), ''
                        )
                    )
                ) AS clean_cntry

            FROM bronze.erp_loc_a101
        )
        INSERT INTO silver.erp_loc_a101 (
            cid,
            cntry
        )
        SELECT
            cid,

            CASE
                WHEN clean_cntry = 'DE'
                    THEN 'Germany'
                WHEN clean_cntry IN ('US', 'USA')
                    THEN 'United States'
                WHEN clean_cntry IS NULL OR clean_cntry = ''
                    THEN 'n/a'
                ELSE
                    CASE clean_cntry
                        WHEN 'AUSTRALIA' THEN 'Australia'
                        WHEN 'CANADA' THEN 'Canada'
                        WHEN 'FRANCE' THEN 'France'
                        WHEN 'GERMANY' THEN 'Germany'
                        WHEN 'UNITED KINGDOM' THEN 'United Kingdom'
                        WHEN 'UNITED STATES' THEN 'United States'
                        ELSE clean_cntry
                    END
            END AS cntry

        FROM cleaned_locations;

        SET @end_time = SYSDATETIME();

        PRINT '>> ERP Location Information Loaded';
        PRINT '>> Load Duration: ' +
            CAST(
                DATEDIFF_BIG(MILLISECOND, @start_time, @end_time)
                / 1000.0 AS VARCHAR(30)
            ) + ' seconds';


        -- =========================================================
        -- 6. ERP PRODUCT CATEGORY
        -- =========================================================

        SET @start_time = SYSDATETIME();

        PRINT '>> Truncating Table: silver.erp_px_cat_g1v2';

        TRUNCATE TABLE silver.erp_px_cat_g1v2;

        PRINT '>> Inserting Data Into: silver.erp_px_cat_g1v2';

        INSERT INTO silver.erp_px_cat_g1v2 (
            id,
            cat,
            subcat,
            maintenance
        )
        SELECT
            id,
            cat,
            subcat,

            TRIM(
                REPLACE(
                    REPLACE(maintenance, CHAR(13), ''),
                    CHAR(10), ''
                )
            ) AS maintenance

        FROM bronze.erp_px_cat_g1v2;

        SET @end_time = SYSDATETIME();

        PRINT '>> ERP Product Category Loaded';
        PRINT '>> Load Duration: ' +
            CAST(
                DATEDIFF_BIG(MILLISECOND, @start_time, @end_time)
                / 1000.0 AS VARCHAR(30)
            ) + ' seconds';


        -- =========================================================
        -- COMMIT TRANSACTION
        -- =========================================================

        COMMIT TRANSACTION;

        SET @batch_end_time = SYSDATETIME();

        PRINT '========================================';
        PRINT 'Silver Layer Loaded Successfully';
        PRINT '>> Total Batch Duration: ' +
            CAST(
                DATEDIFF_BIG(
                    MILLISECOND,
                    @batch_start_time,
                    @batch_end_time
                ) / 1000.0 AS VARCHAR(30)
            ) + ' seconds';
        PRINT '========================================';

    END TRY

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        PRINT '========================================';
        PRINT 'ERROR OCCURRED DURING SILVER LOAD';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Number: ' +
            CAST(ERROR_NUMBER() AS VARCHAR(20));
        PRINT 'Error Line: ' +
            CAST(ERROR_LINE() AS VARCHAR(20));
        PRINT '========================================';

        THROW;

    END CATCH
END;
GO
