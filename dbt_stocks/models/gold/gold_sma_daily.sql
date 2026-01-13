{{ config(materialized='table', schema='gold') }}

WITH src AS (
  SELECT
    symbol,
    trade_date,
    close
  FROM {{ ref('gold_ohlc_daily') }}
),

sma AS (
  SELECT
    symbol,
    trade_date,
    close,

    AVG(close) OVER (
      PARTITION BY symbol
      ORDER BY trade_date
      ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    ) AS sma_20d,

    AVG(close) OVER (
      PARTITION BY symbol
      ORDER BY trade_date
      ROWS BETWEEN 49 PRECEDING AND CURRENT ROW
    ) AS sma_50d,

    AVG(close) OVER (
      PARTITION BY symbol
      ORDER BY trade_date
      ROWS BETWEEN 199 PRECEDING AND CURRENT ROW
    ) AS sma_200d

  FROM src
)

SELECT * FROM sma
