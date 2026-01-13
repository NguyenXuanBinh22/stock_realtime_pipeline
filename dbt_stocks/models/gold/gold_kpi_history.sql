{{ config(
    materialized         = 'incremental',
    schema               = 'gold',
    unique_key           = ['symbol', 'market_time_utc'],
    incremental_strategy = 'merge'
) }}

-- 1) Lấy dữ liệu KPI từ Silver
WITH base AS (
    SELECT
        symbol,
        current_price,
        change_amount,
        change_percent,
        day_open,
        day_high,
        day_low,
        prev_close,
        market_time_us   AS market_time_local,
        market_time_utc,
        fetched_at       AS as_of_time
    FROM {{ ref('silver_stock_quotes') }}
),

-- 2) Khi incremental: chỉ giữ các bản CHƯA có trong history
filtered AS (
    SELECT
        b.*
    FROM base b
    {% if is_incremental() %}
    LEFT JOIN {{ this }} h
      ON  h.symbol          = b.symbol
      AND h.market_time_utc = b.market_time_utc
    WHERE h.symbol IS NULL   -- chỉ giữ bản mới, chưa tồn tại trong bảng history
    {% endif %}
)

-- 3) Output history table
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
    market_time_utc,
    as_of_time
FROM filtered
