-- create raw tables
CREATE TABLE raw_network_events (
    subscriber_id INT,           
    event_timestamp TIMESTAMP,
    event_type TEXT,
    cell_tower_id INT,
    region TEXT
);

CREATE TABLE raw_subscribers (
    subscriber_id INT PRIMARY KEY,
    gender TEXT,
    age INT,
    state TEXT,
    signup_date DATE,
    segment TEXT,
    plan_type TEXT,
    is_active BOOLEAN
);

CREATE TABLE raw_daily_usage (
    subscriber_id INT,
    usage_date DATE,
    data_mb NUMERIC,
    voice_minutes NUMERIC,
    sms_count INT,
    recharge_amount NUMERIC,
    network_issues INT,
    PRIMARY KEY(subscriber_id, usage_date)
);

SELECT * FROM raw_network_events LIMIT 5;
SELECT * FROM raw_subscribers LIMIT 5;
SELECT * FROM raw_daily_usage LIMIT 5;

-- create staging tables
CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE staging.stg_network_events AS
WITH cleaned AS (
    SELECT *
    FROM public.raw_network_events
    WHERE subscriber_id IS NOT NULL
      AND event_timestamp IS NOT NULL
      AND event_type IS NOT NULL
      AND event_type IN ('dropped_call','failed_connection','handover_failure')
      AND event_timestamp >= NOW() - INTERVAL '12 months'
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY subscriber_id, event_timestamp, LOWER(TRIM(event_type))
               ORDER BY event_timestamp DESC
           ) AS rn
    FROM cleaned
)
SELECT
    subscriber_id::INT AS subscriber_id,
    event_timestamp::TIMESTAMP AS event_timestamp,
    LOWER(TRIM(event_type)) AS event_type,
    cell_tower_id::INT AS cell_tower_id,
    INITCAP(TRIM(region)) AS region,
    EXTRACT(YEAR FROM event_timestamp) AS event_year,
    EXTRACT(MONTH FROM event_timestamp) AS event_month,
    EXTRACT(DAY FROM event_timestamp) AS event_day
FROM ranked
WHERE rn = 1;

CREATE TABLE staging.stg_subscribers AS
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY subscriber_id ORDER BY signup_date DESC) AS rn
    FROM public.raw_subscribers
)
SELECT
    subscriber_id::int AS subscriber_id,
    INITCAP(TRIM(gender)) AS gender,
    CASE WHEN age BETWEEN 18 AND 100 THEN age::int ELSE NULL END AS age,
    INITCAP(TRIM(state)) AS state,
    signup_date::date AS signup_date,
    LOWER(TRIM(segment)) AS segment,
    LOWER(TRIM(plan_type)) AS plan_type,
   CASE 
	    WHEN LOWER(TRIM(is_active::text)) IN ('true','t','1') THEN TRUE
	    WHEN LOWER(TRIM(is_active::text)) IN ('false','f','0') THEN FALSE
	    ELSE NULL
	END AS is_active,
    EXTRACT(YEAR FROM signup_date) AS signup_year,
    EXTRACT(MONTH FROM signup_date) AS signup_month
FROM ranked
WHERE rn = 1
  AND subscriber_id IS NOT NULL
  AND gender IS NOT NULL
  AND state IS NOT NULL
  AND segment IN ('prepaid','postpaid')
  AND plan_type IN ('daily','weekly','monthly');
	
CREATE TABLE staging.stg_daily_usage AS
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY subscriber_id, usage_date ORDER BY usage_date DESC) AS rn
    FROM public.raw_daily_usage
)
SELECT
    r.subscriber_id::int AS subscriber_id,
    r.usage_date::date AS usage_date,
    COALESCE(r.data_mb::numeric, 0) AS data_mb,
    COALESCE(r.voice_minutes::numeric, 0) AS voice_minutes,
    COALESCE(r.sms_count::int, 0) AS sms_count,
    COALESCE(r.recharge_amount::numeric, 0) AS recharge_amount,
    COALESCE(r.network_issues::int, 0) AS network_issues,
    EXTRACT(YEAR FROM r.usage_date) AS usage_year,
    EXTRACT(MONTH FROM r.usage_date) AS usage_month
FROM ranked r
JOIN staging.stg_subscribers s
    ON r.subscriber_id = s.subscriber_id
WHERE rn = 1;

SELECT * FROM staging.stg_network_events LIMIT 5;
SELECT * FROM staging.stg_subscribers LIMIT 5;
SELECT * FROM staging.stg_daily_usage LIMIT 5;
SELECT COUNT(subscriber_id) FROM staging.stg_daily_usage;

-- create feature engineering tables
CREATE SCHEMA IF NOT EXISTS features;
CREATE TABLE features.fe_network_events AS
WITH events_30d AS (
    SELECT
        subscriber_id,
        SUM(daily_events) AS events_30d_count,
        SUM(dropped_calls_daily) AS dropped_calls_30d,
        SUM(failed_connections_daily) AS failed_connections_30d,
        SUM(handover_failures_daily) AS handover_failures_30d,
        AVG(daily_events) AS avg_events_per_day,
        MAX(daily_events) AS max_events_in_a_day
    FROM (
        SELECT
            subscriber_id,
            event_timestamp::date AS event_date,
            COUNT(*) AS daily_events,
            COUNT(*) FILTER (WHERE event_type='dropped_call') AS dropped_calls_daily,
            COUNT(*) FILTER (WHERE event_type='failed_connection') AS failed_connections_daily,
            COUNT(*) FILTER (WHERE event_type='handover_failure') AS handover_failures_daily
        FROM staging.stg_network_events
        WHERE event_timestamp >= NOW() - INTERVAL '30 days'
        GROUP BY subscriber_id, event_timestamp::date
    ) AS daily_counts
    GROUP BY subscriber_id
),
events_7d AS (
    SELECT
        subscriber_id,
        COUNT(*) AS events_7d_count,
        COUNT(*) FILTER (WHERE event_type='dropped_call') AS dropped_calls_7d,
        COUNT(*) FILTER (WHERE event_type='failed_connection') AS failed_connections_7d,
        COUNT(*) FILTER (WHERE event_type='handover_failure') AS handover_failures_7d,
        CASE WHEN COUNT(*) > 0 THEN TRUE ELSE FALSE END AS had_network_issue_last_week
    FROM staging.stg_network_events
    WHERE event_timestamp >= NOW() - INTERVAL '7 days'
    GROUP BY subscriber_id
)
SELECT
    s.subscriber_id,
    COALESCE(e7.events_7d_count,0) AS events_7d_count,
    COALESCE(e7.dropped_calls_7d,0) AS dropped_calls_7d,
    COALESCE(e7.failed_connections_7d,0) AS failed_connections_7d,
    COALESCE(e7.handover_failures_7d,0) AS handover_failures_7d,
    COALESCE(e7.had_network_issue_last_week,FALSE) AS had_network_issue_last_week,
    COALESCE(e30.events_30d_count,0) AS events_30d_count,
    COALESCE(e30.dropped_calls_30d,0) AS dropped_calls_30d,
    COALESCE(e30.failed_connections_30d,0) AS failed_connections_30d,
    COALESCE(e30.handover_failures_30d,0) AS handover_failures_30d,
    COALESCE(e30.avg_events_per_day,0) AS avg_events_per_day,
    COALESCE(e30.max_events_in_a_day,0) AS max_events_in_a_day
FROM staging.stg_subscribers s
LEFT JOIN events_7d e7 ON s.subscriber_id = e7.subscriber_id
LEFT JOIN events_30d e30 ON s.subscriber_id = e30.subscriber_id;

CREATE TABLE features.fe_subscribers AS
SELECT
    subscriber_id,
    age,
    gender,
    segment,
    plan_type,
    is_active,
    state,
    signup_date,
    signup_year,
    signup_month,
    -- Derived Features
    (CURRENT_DATE - signup_date)::INT AS signup_tenure_days,
    CASE 
        WHEN age BETWEEN 18 AND 25 THEN '18-25'
        WHEN age BETWEEN 26 AND 35 THEN '26-35'
        WHEN age BETWEEN 36 AND 50 THEN '36-50'
        ELSE '51+' 
    END AS age_bucket,
    CASE 
        WHEN (CURRENT_DATE - signup_date)::INT < 365 THEN 'short'
        WHEN (CURRENT_DATE - signup_date)::INT BETWEEN 365 AND 1095 THEN 'medium'
        ELSE 'long'
    END AS tenure_bucket,
    CASE 
        WHEN state IN ('Lagos','Abuja','Rivers') THEN 'Urban'
        ELSE 'Rural'
    END AS region_type
FROM staging.stg_subscribers
WHERE subscriber_id IS NOT NULL;

CREATE TABLE features.fe_daily_usage AS
WITH usage_enriched AS (
    -- Join with subscriber info for static features
    SELECT
        u.subscriber_id,
        u.usage_date,
        u.data_mb,
        u.voice_minutes,
        u.sms_count,
        u.recharge_amount,
        u.network_issues,
        s.age,
        s.gender,
        s.segment,
        s.plan_type,
        s.state,
        s.is_active
    FROM staging.stg_daily_usage u
    JOIN staging.stg_subscribers s
        ON u.subscriber_id = s.subscriber_id
),
usage_rolling AS (
    SELECT *,
        -- 30-day rolling averages
        AVG(data_mb) OVER(PARTITION BY subscriber_id ORDER BY usage_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS data_mb_30d_avg,
        AVG(voice_minutes) OVER(PARTITION BY subscriber_id ORDER BY usage_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS voice_minutes_30d_avg,
        AVG(sms_count) OVER(PARTITION BY subscriber_id ORDER BY usage_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS sms_30d_avg,
        AVG(recharge_amount) OVER(PARTITION BY subscriber_id ORDER BY usage_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS recharge_30d_avg,
        SUM(network_issues) OVER(PARTITION BY subscriber_id ORDER BY usage_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS network_issues_7d_sum,
        -- Zero usage flag
        CASE WHEN data_mb = 0 AND voice_minutes = 0 THEN 1 ELSE 0 END AS zero_usage_flag
    FROM usage_enriched
),
islands AS (
    -- Create islands for consecutive zero usage
    SELECT *,
        SUM(CASE WHEN zero_usage_flag = 0 THEN 1 ELSE 0 END) OVER(PARTITION BY subscriber_id ORDER BY usage_date) AS island_group
    FROM usage_rolling
),
streaks AS (
    -- Count consecutive zeros per island
    SELECT *,
        CASE 
            WHEN zero_usage_flag = 1 THEN ROW_NUMBER() OVER(PARTITION BY subscriber_id, island_group ORDER BY usage_date)
            ELSE 0
        END AS consecutive_zero_days
    FROM islands
)
SELECT
    subscriber_id,
    usage_date,
    age,
    gender,
    segment,
    plan_type,
    state,
    is_active,
    data_mb,
    voice_minutes,
    sms_count,
    recharge_amount,
    network_issues,
    data_mb_30d_avg,
    voice_minutes_30d_avg,
    sms_30d_avg,
    recharge_30d_avg,
    network_issues_7d_sum,
    consecutive_zero_days,
    EXTRACT(YEAR FROM usage_date) AS usage_year,
    EXTRACT(MONTH FROM usage_date) AS usage_month
FROM streaks;

SELECT * FROM features.fe_network_events LIMIT 5;
SELECT * FROM features.fe_subscribers LIMIT 5;
SELECT * FROM features.fe_daily_usage LIMIT 5;

-- create analytics tables
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE TABLE analytics.fact_network_events AS
SELECT
    subscriber_id,
    events_7d_count,
    dropped_calls_7d,
    failed_connections_7d,
    handover_failures_7d,
    had_network_issue_last_week,
    events_30d_count,
    dropped_calls_30d,
    failed_connections_30d,
    handover_failures_30d,
    avg_events_per_day,
    max_events_in_a_day
FROM features.fe_network_events;

CREATE TABLE analytics.dim_subscribers AS
SELECT
    subscriber_id,
    age,
    age_bucket,
    gender,
    segment,
    plan_type,
    is_active,
    state,
    region_type,
    signup_date,
    signup_year,
    signup_month,
    signup_tenure_days,
    tenure_bucket
FROM features.fe_subscribers;

CREATE TABLE analytics.fact_daily_usage AS
SELECT
    subscriber_id,
    usage_date,
    age,
    gender,
    segment,
    plan_type,
    state,
    is_active,
    data_mb,
    voice_minutes,
    sms_count,
    recharge_amount,
    network_issues,
    data_mb_30d_avg,
    voice_minutes_30d_avg,
    sms_30d_avg,
    recharge_30d_avg,
    network_issues_7d_sum,
    consecutive_zero_days,
    usage_year,
    usage_month,
	-- churn proxy flag 
	CASE WHEN consecutive_zero_days >= 30 THEN 1 ELSE 0 END AS churn_proxy_30d
FROM features.fe_daily_usage;

CREATE TABLE analytics.fact_subscriber_summary AS
WITH usage_agg AS (
    SELECT
        subscriber_id,
        -- Aggregate usage metrics over the last 30 days
        SUM(data_mb) AS total_data_30d,
        AVG(data_mb) AS avg_data_30d,
        SUM(voice_minutes) AS total_voice_30d,
        AVG(voice_minutes) AS avg_voice_30d,
        SUM(sms_count) AS total_sms_30d,
        AVG(sms_count) AS avg_sms_30d,
        SUM(recharge_amount) AS total_recharge_30d,
        AVG(recharge_amount) AS avg_recharge_30d,
        MAX(consecutive_zero_days) AS max_zero_days_30d,
        SUM(network_issues) AS total_network_issues_30d
    FROM analytics.fact_daily_usage
    WHERE usage_date >= NOW() - INTERVAL '30 days'
    GROUP BY subscriber_id
)
SELECT
    s.subscriber_id,
    s.age,
    s.age_bucket,
    s.gender,
    s.segment,
    s.plan_type,
    s.is_active,
    s.state,
    s.region_type,
    u.total_data_30d,
    u.avg_data_30d,
    u.total_voice_30d,
    u.avg_voice_30d,
    u.total_sms_30d,
    u.avg_sms_30d,
    u.total_recharge_30d,
    u.avg_recharge_30d,
    u.max_zero_days_30d,
    u.total_network_issues_30d,
    n.events_7d_count,
    n.dropped_calls_7d,
    n.failed_connections_7d,
    n.handover_failures_7d,
    n.had_network_issue_last_week,
    n.events_30d_count,
    n.dropped_calls_30d,
    n.failed_connections_30d,
    n.handover_failures_30d,
    n.avg_events_per_day,
    n.max_events_in_a_day,
    -- Proxy churn flag
CASE 
    WHEN u.max_zero_days_30d >= 7 THEN 1
    WHEN u.avg_data_30d < 50 THEN 1
    WHEN u.avg_recharge_30d = 0 THEN 1
    WHEN u.total_network_issues_30d >= 5 THEN 1
    ELSE 0
END AS churn_proxy_30d
FROM analytics.dim_subscribers s
LEFT JOIN usage_agg u ON s.subscriber_id = u.subscriber_id
LEFT JOIN analytics.fact_network_events n ON s.subscriber_id = n.subscriber_id;

SELECT * FROM analytics.fact_network_events LIMIT 5;
SELECT * FROM analytics.dim_subscribers LIMIT 5;
SELECT * FROM analytics.fact_daily_usage LIMIT 5;
SELECT * FROM analytics.fact_subscriber_summary LIMIT 5;