{{ config(materialized='table', schema='gold') }}

WITH base AS (
  SELECT
    symbol,
    SAFE_CAST(current_price AS FLOAT64) AS price,
    market_time_us
  FROM {{ ref('silver_stock_quotes') }}
  WHERE SAFE_CAST(current_price AS FLOAT64) > 0
),

bucketed AS (
  SELECT
    symbol,
    DATE(market_time_us) AS trade_date,
    price,
    market_time_us
  FROM base
),

ohlc AS (
  SELECT
    symbol,
    trade_date,

    ARRAY_AGG(price ORDER BY market_time_us ASC LIMIT 1)[OFFSET(0)] AS open,
    MAX(price) AS high,
    MIN(price) AS low,
    ARRAY_AGG(price ORDER BY market_time_us DESC LIMIT 1)[OFFSET(0)] AS close,

    MAX(market_time_us) AS last_tick_time
  FROM bucketed
  GROUP BY symbol, trade_date
)

SELECT * FROM ohlc
