DECLARE @date_from date = '2024-01-01';
DECLARE @date_to   date = '2024-12-31';

WITH d AS (
    SELECT
        fd.deal_id,
        fd.lead_acquisition_date,
        fd.expected_close_date,
        fd.actual_close_date,
        fd.deal_value,
        fd.probability_pct,
        os.org_size_label,
        ow.owner_name AS sales_agent,
        pr.product_name AS product,
        st.status_name AS status,
        st.status_sequence,
        sg.stage_name  AS stage,
        sg.stage_sequence,
        CASE WHEN fd.actual_close_date IS NOT NULL AND st.status_name IN ('Closed Won','Won','Closed Deal') THEN 1 ELSE 0 END AS is_won,
        CASE WHEN fd.actual_close_date IS NOT NULL AND st.status_name IN ('Closed Lost','Lost','Churned Customer') THEN 1 ELSE 0 END AS is_lost,
        CASE WHEN fd.actual_close_date IS NULL THEN 1 ELSE 0 END AS is_open,
        fd.deal_value * (fd.probability_pct / 100.0) AS expected_value,
        CASE WHEN fd.actual_close_date IS NOT NULL AND fd.lead_acquisition_date IS NOT NULL
             THEN DATEDIFF(DAY, fd.lead_acquisition_date, fd.actual_close_date) END AS days_to_close,
        CASE WHEN fd.actual_close_date IS NOT NULL AND fd.expected_close_date IS NOT NULL
               AND fd.actual_close_date > fd.expected_close_date THEN 1 ELSE 0 END AS is_late,

        CASE
            WHEN fd.probability_pct BETWEEN 0  AND 25 THEN '0-25%'
            WHEN fd.probability_pct BETWEEN 26 AND 50 THEN '26-50%'
            WHEN fd.probability_pct BETWEEN 51 AND 75 THEN '51-75%'
            ELSE '76-100%'
        END AS probability_bucket
    FROM dbo.fact_deal fd
    JOIN dbo.dim_org_size os ON os.org_size_id = fd.org_size_id
    JOIN dbo.dim_owner ow    ON ow.owner_id    = fd.owner_id
    JOIN dbo.dim_product pr  ON pr.product_id  = fd.product_id
    JOIN dbo.dim_status st   ON st.status_id   = fd.status_id
    JOIN dbo.dim_stage  sg   ON sg.stage_id    = fd.stage_id
    WHERE fd.lead_acquisition_date BETWEEN @date_from AND @date_to
),
kpi AS (
    SELECT
        -- Top KPI tiles (Performance Overview)
        SUM(CASE WHEN is_won = 1 THEN deal_value ELSE 0 END) AS closed_deal_value,
        CAST(100.0 * SUM(CASE WHEN is_won = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0) AS decimal(10,2)) AS conversion_rate_pct,
        AVG(CASE WHEN is_won = 1 THEN CAST(days_to_close AS decimal(10,2)) END) AS avg_days_to_close,
        CAST(100.0 * SUM(is_won) / NULLIF(SUM(CASE WHEN is_won=1 OR is_lost=1 THEN 1 ELSE 0 END),0) AS decimal(10,2)) AS win_rate_pct,
        CAST(100.0 * SUM(is_lost) / NULLIF(SUM(CASE WHEN is_won=1 OR is_lost=1 THEN 1 ELSE 0 END),0) AS decimal(10,2)) AS lost_rate_pct,
        SUM(is_open) AS leads_open,

        -- Forecast & Risk tiles
        SUM(expected_value) AS expected_value_total,
        SUM(CASE WHEN expected_close_date IS NOT NULL THEN 1 ELSE 0 END) AS expected_closed_deals,
        CAST(100.0 * SUM(CASE WHEN probability_pct >= 75 THEN 1 ELSE 0 END) / NULLIF(COUNT(*),0) AS decimal(10,2)) AS high_prob_deals_pct,
        SUM(CASE WHEN probability_pct < 50 OR is_late = 1 THEN 1 ELSE 0 END) AS high_risk_deals
    FROM d
),
by_product_closed AS (
    -- Donut: Total Leads Closed by Product
    SELECT
        product,
        COUNT(*) AS leads_closed
    FROM d
    WHERE is_won = 1 OR is_lost = 1
    GROUP BY product
),
conv_by_country_stub AS (
    -- If you have country in your model, replace stub with real column.
    -- Conversion Rate by Country = won deals / total deals (or / closed deals) depending on your Tableau definition.
    SELECT
        CAST(NULL AS nvarchar(100)) AS country,
        CAST(NULL AS decimal(10,2)) AS conversion_rate_pct
),
actual_vs_expected_by_month AS (
    -- Chart: Actual vs Expected Close Deal Value by Month
    SELECT
        DATEFROMPARTS(YEAR(lead_acquisition_date), MONTH(lead_acquisition_date), 1) AS month_start,
        SUM(CASE WHEN is_won = 1 THEN deal_value ELSE 0 END) AS actual_closed_value,
        SUM(expected_value) AS expected_closed_value
    FROM d
    GROUP BY DATEFROMPARTS(YEAR(lead_acquisition_date), MONTH(lead_acquisition_date), 1)
),
prob_bucket AS (
    -- Chart: Expected Closed Deal by Probability Bucket (counts or expected value)
    SELECT
        probability_bucket,
        COUNT(*) AS deals,
        SUM(expected_value) AS expected_value
    FROM d
    GROUP BY probability_bucket
),
agent_closed_by_product AS (
    -- Chart: Total Leads Closed (stacked by product) per Sales Agent
    SELECT
        sales_agent,
        product,
        COUNT(*) AS leads_closed
    FROM d
    WHERE is_won = 1 OR is_lost = 1
    GROUP BY sales_agent, product
),
detail_table AS (
    -- Detail table: per agent metrics
    SELECT
        sales_agent,
        COUNT(*) AS leads_total,
        SUM(CASE WHEN is_won=1 OR is_lost=1 THEN 1 ELSE 0 END) AS leads_closed,
        SUM(CASE WHEN is_won=1 THEN deal_value ELSE 0 END) AS closed_deal_value,
        AVG(CASE WHEN is_won=1 THEN deal_value END) AS avg_closed_deal_value,
        AVG(CASE WHEN is_won=1 THEN CAST(days_to_close AS decimal(10,2)) END) AS avg_days_to_close
    FROM d
    GROUP BY sales_agent
)

-- =========================
-- OUTPUTS 
-- =========================

-- 1) KPI tiles (compare to top row of dashboard)
SELECT * FROM kpi;

-- 2) Total leads closed by product
SELECT * FROM by_product_closed ORDER BY leads_closed DESC;

-- 3) Actual vs Expected closed value by month (line/area chart)
SELECT * FROM actual_vs_expected_by_month ORDER BY month_start;

-- 4) Probability bucket chart (counts + expected value)
SELECT * FROM prob_bucket ORDER BY probability_bucket;

-- 5) Stacked bars: Leads closed by agent and product
SELECT * FROM agent_closed_by_product ORDER BY sales_agent, product;

-- 6) Detail table per agent
SELECT * FROM detail_table ORDER BY closed_deal_value DESC;