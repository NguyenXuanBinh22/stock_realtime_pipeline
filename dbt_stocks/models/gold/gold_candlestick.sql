{{ config(
    materialized='table',
    schema='gold'
) }}

-- 1) Lấy dữ liệu từ Silver với timestamp US (chuẩn thị trường Mỹ)
WITH enriched AS (
    SELECT
        symbol,

        -- dùng market_time_us để gom nhóm theo ngày thị trường
        CAST(market_time_us AS DATE) AS candle_date,

        current_price,
        day_low,
        day_high,

        -- OPEN: giá đầu tiên trong ngày
        FIRST_VALUE(current_price) OVER (
            PARTITION BY symbol, CAST(market_time_us AS DATE)
            ORDER BY market_time_us
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS candle_open,

        -- CLOSE: giá cuối cùng trong ngày
        LAST_VALUE(current_price) OVER (
            PARTITION BY symbol, CAST(market_time_us AS DATE)
            ORDER BY market_time_us
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS candle_close
    FROM {{ ref('silver_stock_quotes') }}
),

-- 2) Aggregate thành candle 1 ngày
daily AS (
    SELECT
        symbol,
        candle_date,
        MIN(day_low)  AS candle_low,
        MAX(day_high) AS candle_high,
        ANY_VALUE(candle_open)  AS candle_open,
        ANY_VALUE(candle_close) AS candle_close,
        AVG(current_price) AS trend_line
    FROM enriched
    GROUP BY symbol, candle_date
),

-- 3) Lấy 12 ngày gần nhất cho từng symbol
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY symbol
            ORDER BY candle_date DESC
        ) AS rn
    FROM daily
)

-- 4) Output final
SELECT
    symbol,
    candle_date AS candle_time,
    candle_low,
    candle_high,
    candle_open,
    candle_close,
    trend_line
FROM ranked
ORDER BY symbol, candle_time
