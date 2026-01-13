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

WITH price AS (
  SELECT
    symbol,
    trade_date,
    close,
    close - LAG(close) OVER (
      PARTITION BY symbol
      ORDER BY trade_date
    ) AS delta
  FROM {{ ref('gold_ohlc_daily') }}
),

gain_loss AS (
  SELECT
    symbol,
    trade_date,
    CASE WHEN delta > 0 THEN delta ELSE 0 END AS gain,
    CASE WHEN delta < 0 THEN ABS(delta) ELSE 0 END AS loss
  FROM price
),

avg_gain_loss AS (
  SELECT
    symbol,
    trade_date,
    AVG(gain) OVER (
      PARTITION BY symbol
      ORDER BY trade_date
      ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
    ) AS avg_gain_14,
    AVG(loss) OVER (
      PARTITION BY symbol
      ORDER BY trade_date
      ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
    ) AS avg_loss_14
  FROM gain_loss
),

rsi AS (
  SELECT
    symbol,
    trade_date,
    CASE
      WHEN avg_loss_14 = 0 THEN 100
      ELSE 100 - (100 / (1 + avg_gain_14 / avg_loss_14))
    END AS rsi_14
  FROM avg_gain_loss
)

SELECT
  symbol,
  trade_date,
  rsi_14
FROM rsi
