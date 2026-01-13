{{ config(
    materialized='table',
    schema='gold'
) }}

WITH ranked AS (
    SELECT
        symbol,
        current_price,
        change_amount,
        change_percent,
        day_high,
        day_low,
        day_open,
        prev_close,
        market_time_us,
        market_time_utc,
        fetched_at,

        ROW_NUMBER() OVER (
            PARTITION BY symbol
            ORDER BY fetched_at DESC
        ) AS rn
    FROM {{ ref('silver_stock_quotes') }}
)

SELECT
    symbol,
    
    -- KPI chính
    current_price,
    change_amount,
    change_percent,

    -- bổ sung KPI quan trọng
    day_open,
    day_high,
    day_low,
    prev_close,

    -- timestamp để dashboard biết thời điểm dữ liệu
    market_time_us AS market_time_local,
    fetched_at     AS as_of_time

FROM ranked
WHERE rn = 1
ORDER BY symbol
