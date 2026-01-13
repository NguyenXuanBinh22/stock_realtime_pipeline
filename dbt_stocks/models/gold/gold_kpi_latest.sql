{{ config(
    materialized='view',
    schema='gold'
) }}

WITH ranked AS (
    SELECT
        symbol,
        current_price,
        change_amount,
        change_percent,
        day_open,
        day_high,
        day_low,
        prev_close,
        market_time_local,
        as_of_time,
        ROW_NUMBER() OVER (
            PARTITION BY symbol
            ORDER BY market_time_utc DESC
        ) AS rn
    FROM {{ ref('gold_kpi_history') }}
)

SELECT
    symbol,
    current_price,
    change_amount,
    change_percent,
    day_open,
    day_high,
    day_low,
    prev_close,
    market_time_local,
    as_of_time
FROM ranked
WHERE rn = 1
ORDER BY symbol
