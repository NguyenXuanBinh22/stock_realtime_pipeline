{{ config(
    materialized         = 'incremental',
    schema               = 'silver',
    unique_key           = ['symbol', 'market_timestamp_raw'],
    incremental_strategy = 'merge'
) }}

-- 1) Load từ Bronze (đã rename)
WITH base AS (
    SELECT
        symbol,

        -- CAST TYPE
        CAST(current_price   AS FLOAT64) AS current_price,
        CAST(change_amount   AS FLOAT64) AS change_amount,
        CAST(change_percent  AS FLOAT64) AS change_percent,
        CAST(day_high        AS FLOAT64) AS day_high,
        CAST(day_low         AS FLOAT64) AS day_low,
        CAST(day_open        AS FLOAT64) AS day_open,
        CAST(prev_close      AS FLOAT64) AS prev_close,

        -- timestamp thị trường (epoch giây)
        CAST(market_timestamp AS INT64) AS market_timestamp_raw,

        -- convert timestamp ngay tại đây
        TIMESTAMP_SECONDS(CAST(market_timestamp AS INT64)) AS market_time_utc,
        DATETIME(
            TIMESTAMP_SECONDS(CAST(market_timestamp AS INT64)),
            "America/New_York"
        ) AS market_time_us,

        -- thời điểm crawl (epoch giây -> TIMESTAMP)
        TIMESTAMP_SECONDS(CAST(fetched_at AS INT64)) AS fetched_at
    FROM {{ ref('bronze_stock_quotes') }}
),

-- 1.5) Chỉ lấy bản CHƯA có trong Silver (khi incremental)
filtered AS (
    SELECT
        b.*
    FROM base b
    {% if is_incremental() %}
    LEFT JOIN {{ this }} s
      ON  s.symbol              = b.symbol
      AND s.market_timestamp_raw = b.market_timestamp_raw
    WHERE s.symbol IS NULL  -- chỉ giữ bản chưa tồn tại
    {% endif %}
),

-- 2) Remove duplicate trong batch mới
dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY symbol, market_timestamp_raw
            ORDER BY fetched_at DESC
        ) AS rn
    FROM filtered
),

-- 3) Validate data
validated AS (
    SELECT *
    FROM dedup
    WHERE rn = 1
      AND current_price > 0
      AND prev_close    > 0
      AND day_open      > 0
      AND day_high      >= day_low
)

-- 4) Output Silver table
SELECT
    symbol,
    current_price,
    change_amount,
    change_percent,
    day_high,
    day_low,
    day_open,
    prev_close,
    market_timestamp_raw,
    market_time_utc,
    market_time_us,
    fetched_at
FROM validated
ORDER BY market_time_utc DESC
