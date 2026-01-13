{{ 
  config(
    materialized='table',
    schema='gold',
    partition_by={
      "field": "trade_date",
      "data_type": "date"
    },
    cluster_by=["symbol"]
  ) 
}}

WITH base AS (
  SELECT
    symbol,
    trade_date,
    high,
    low,
    close,
    LAG(close) OVER (
      PARTITION BY symbol
      ORDER BY trade_date
    ) AS prev_close
  FROM {{ ref('gold_ohlc_daily') }}
),

true_range AS (
  SELECT
    symbol,
    trade_date,
    GREATEST(
      high - low,
      ABS(high - prev_close),
      ABS(low - prev_close)
    ) AS tr
  FROM base
),

atr AS (
  SELECT
    symbol,
    trade_date,
    tr,

    -- ATR 14 ngày (chuẩn)
    AVG(tr) OVER (
      PARTITION BY symbol
      ORDER BY trade_date
      ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
    ) AS atr_14
  FROM true_range
)

SELECT
  symbol,
  trade_date,
  atr_14
FROM atr
