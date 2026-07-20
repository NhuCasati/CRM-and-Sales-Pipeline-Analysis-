/* ============================================================
   CRM PIPELINE (SQL Server) — staging → dims → fact → Tableau view
   Matches dashboards like: Performance Overview + Forecast/Risk
   ============================================================ */

------------------------------------------------------------
-- 0) STAGING (SSIS lands raw file here)
------------------------------------------------------------
CREATE TABLE dbo.stg_crm_deals_raw (
    load_dts DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),

    org_size_label NVARCHAR(50) NULL,     
    owner_name NVARCHAR(100) NULL,        
    lead_acquisition_date DATE NULL,
    product_name NVARCHAR(100) NULL,      
    status_name NVARCHAR(100) NULL,       
    status_sequence INT NULL,
    stage_name NVARCHAR(100) NULL,        
    stage_sequence INT NULL,
    deal_value DECIMAL(18,2) NULL,        
    probability_pct DECIMAL(5,2) NULL,    
    expected_close_date DATE NULL,
    actual_close_date DATE NULL,
);

------------------------------------------------------------
-- 1) DIMENSIONS
------------------------------------------------------------
CREATE TABLE dbo.dim_org_size (
    org_size_id INT IDENTITY PRIMARY KEY,
    org_size_label NVARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE dbo.dim_owner (
    owner_id INT IDENTITY PRIMARY KEY,
    owner_name NVARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE dbo.dim_product (
    product_id INT IDENTITY PRIMARY KEY,
    product_name NVARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE dbo.dim_status (
    status_id INT IDENTITY PRIMARY KEY,
    status_name NVARCHAR(100) NOT NULL,
    status_sequence INT NULL,
    CONSTRAINT UQ_dim_status UNIQUE (status_name)
);

CREATE TABLE dbo.dim_stage (
    stage_id INT IDENTITY PRIMARY KEY,
    stage_name NVARCHAR(100) NOT NULL,
    stage_sequence INT NULL,
    CONSTRAINT UQ_dim_stage UNIQUE (stage_name)
);

-- Optional dims to support dashboard filters
CREATE TABLE dbo.dim_industry (
    industry_id INT IDENTITY PRIMARY KEY,
    industry NVARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE dbo.dim_country (
    country_id INT IDENTITY PRIMARY KEY,
    country NVARCHAR(100) NOT NULL UNIQUE
);
GO

------------------------------------------------------------
-- 2) FACT (one row per deal)
------------------------------------------------------------
CREATE TABLE dbo.fact_deal (
    deal_id BIGINT IDENTITY PRIMARY KEY,

    org_size_id INT NOT NULL,
    owner_id INT NOT NULL,
    product_id INT NOT NULL,
    status_id INT NOT NULL,
    stage_id INT NOT NULL,

    industry_id INT NULL,
    country_id INT NULL,

    lead_acquisition_date DATE NULL,
    expected_close_date DATE NULL,
    actual_close_date DATE NULL,

    deal_value DECIMAL(18,2) NULL,
    probability_pct DECIMAL(5,2) NULL,

    created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT FK_deal_org_size FOREIGN KEY (org_size_id) REFERENCES dbo.dim_org_size(org_size_id),
    CONSTRAINT FK_deal_owner    FOREIGN KEY (owner_id)    REFERENCES dbo.dim_owner(owner_id),
    CONSTRAINT FK_deal_product  FOREIGN KEY (product_id)  REFERENCES dbo.dim_product(product_id),
    CONSTRAINT FK_deal_status   FOREIGN KEY (status_id)   REFERENCES dbo.dim_status(status_id),
    CONSTRAINT FK_deal_stage    FOREIGN KEY (stage_id)    REFERENCES dbo.dim_stage(stage_id),
    CONSTRAINT FK_deal_industry FOREIGN KEY (industry_id) REFERENCES dbo.dim_industry(industry_id),
    CONSTRAINT FK_deal_country  FOREIGN KEY (country_id)  REFERENCES dbo.dim_country(country_id)
);


------------------------------------------------------------
-- 3) POPULATE DIMS (run after SSIS load into staging)
------------------------------------------------------------
INSERT INTO dbo.dim_org_size (org_size_label)
SELECT DISTINCT r.org_size_label
FROM dbo.stg_crm_deals_raw r
WHERE r.org_size_label IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM dbo.dim_org_size d WHERE d.org_size_label = r.org_size_label);

INSERT INTO dbo.dim_owner (owner_name)
SELECT DISTINCT r.owner_name
FROM dbo.stg_crm_deals_raw r
WHERE r.owner_name IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM dbo.dim_owner d WHERE d.owner_name = r.owner_name);

INSERT INTO dbo.dim_product (product_name)
SELECT DISTINCT r.product_name
FROM dbo.stg_crm_deals_raw r
WHERE r.product_name IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM dbo.dim_product d WHERE d.product_name = r.product_name);

INSERT INTO dbo.dim_status (status_name, status_sequence)
SELECT DISTINCT r.status_name, r.status_sequence
FROM dbo.stg_crm_deals_raw r
WHERE r.status_name IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM dbo.dim_status d WHERE d.status_name = r.status_name);

INSERT INTO dbo.dim_stage (stage_name, stage_sequence)
SELECT DISTINCT r.stage_name, r.stage_sequence
FROM dbo.stg_crm_deals_raw r
WHERE r.stage_name IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM dbo.dim_stage d WHERE d.stage_name = r.stage_name);

------------------------------------------------------------
-- 4) CREATE FACT 
------------------------------------------------------------
-- 4.1 fact_deal table
CREATE TABLE dbo.fact_deal (
    deal_id BIGINT IDENTITY PRIMARY KEY,

    org_size_id INT NOT NULL,
    owner_id INT NOT NULL,
    product_id INT NOT NULL,
    stage_id INT NOT NULL,

    industry_id INT NULL,
    country_id INT NULL,

    lead_acquisition_date DATE NULL,
    expected_close_date DATE NULL,
    actual_close_date DATE NULL,

    deal_value DECIMAL(18,2) NULL,
    probability_pct DECIMAL(5,2) NULL,

    created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);

-- 4.2 fact_deal_status table
CREATE TABLE dbo.fact_deal_status (
    deal_id BIGINT PRIMARY KEY,              
    status_id INT NOT NULL,
    status_sequence INT NULL,
    is_won BIT NOT NULL,
    is_lost BIT NOT NULL,
    is_open BIT NOT NULL
);

-- 4.3 fact_deal_forecast table
CREATE TABLE dbo.fact_deal_forecast (
    deal_id BIGINT PRIMARY KEY,              
    expected_value DECIMAL(18,2) NULL,
    risk_level NVARCHAR(30) NULL,
    probability_bucket NVARCHAR(20) NULL,
    is_late BIT NOT NULL
);

------------------------------------------------------------
-- 4) LOAD FACT 
------------------------------------------------------------
-- 5.1 fact_deal table
INSERT INTO dbo.fact_deal (
    org_size_id, owner_id, product_id, stage_id,
    industry_id, country_id,
    lead_acquisition_date, expected_close_date, actual_close_date,
    deal_value, probability_pct
)
SELECT
    os.org_size_id,
    ow.owner_id,
    pr.product_id,
    sg.stage_id,
    r.lead_acquisition_date,
    r.expected_close_date,
    r.actual_close_date,
    r.deal_value,
    r.probability_pct
FROM dbo.stg_crm_deals_raw r
JOIN dbo.dim_org_size os ON os.org_size_label = r.org_size_label
JOIN dbo.dim_owner ow    ON ow.owner_name     = r.owner_name
JOIN dbo.dim_product pr  ON pr.product_name   = r.product_name
JOIN dbo.dim_stage sg    ON sg.stage_name     = r.stage_name


-- 5.2 fact_deal_status table
INSERT INTO dbo.fact_deal_status (
    deal_id, status_id, status_sequence, is_won, is_lost, is_open
)
SELECT
    d.deal_id,
    st.status_id,
    r.status_sequence,

    CASE WHEN r.actual_close_date IS NOT NULL
           AND r.status_name IN ('Closed Won','Won','Closed Deal') THEN 1 ELSE 0 END AS is_won,

    CASE WHEN r.actual_close_date IS NOT NULL
           AND r.status_name IN ('Closed Lost','Lost','Churned Customer') THEN 1 ELSE 0 END AS is_lost,

    CASE WHEN r.actual_close_date IS NULL THEN 1 ELSE 0 END AS is_open
FROM dbo.fact_deal d
JOIN dbo.stg_crm_deals_raw r
  ON r.owner_name = (SELECT owner_name FROM dbo.dim_owner ow WHERE ow.owner_id = d.owner_id)
 AND r.product_name = (SELECT product_name FROM dbo.dim_product pr WHERE pr.product_id = d.product_id)
 AND r.lead_acquisition_date = d.lead_acquisition_date
 AND ISNULL(r.expected_close_date,'1900-01-01') = ISNULL(d.expected_close_date,'1900-01-01')
 AND ISNULL(r.actual_close_date,'1900-01-01')   = ISNULL(d.actual_close_date,'1900-01-01')
 AND ISNULL(r.deal_value,0) = ISNULL(d.deal_value,0)
 AND ISNULL(r.probability_pct,0) = ISNULL(d.probability_pct,0)
JOIN dbo.dim_status st ON st.status_name = r.status_name;

-- fact_deal_forecast table
INSERT INTO dbo.fact_deal_forecast (
    deal_id, expected_value, risk_level, probability_bucket, is_late
)
SELECT
    d.deal_id,
    (d.deal_value * (d.probability_pct / 100.0)) AS expected_value,

    CASE
        WHEN d.probability_pct >= 75 THEN 'High Confidence'
        WHEN d.probability_pct >= 50 THEN 'Moderate'
        ELSE 'High Risk'
    END AS risk_level,

    CASE
        WHEN d.probability_pct BETWEEN 0  AND 25 THEN '0-25%'
        WHEN d.probability_pct BETWEEN 26 AND 50 THEN '26-50%'
        WHEN d.probability_pct BETWEEN 51 AND 75 THEN '51-75%'
        ELSE '76-100%'
    END AS probability_bucket,

    CASE
        WHEN d.actual_close_date IS NOT NULL
         AND d.expected_close_date IS NOT NULL
         AND d.actual_close_date > d.expected_close_date THEN 1
        ELSE 0
    END AS is_late
FROM dbo.fact_deal d;
