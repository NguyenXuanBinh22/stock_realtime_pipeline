{{ config(
    materialized = 'view',
    schema       = 'bronze'
) }}

SELECT
  c AS current_price,
  d AS change_amount,
  dp AS change_percent,
  h AS day_high,
  l AS day_low,
  o AS day_open,
  pc AS prev_close,
  t AS market_timestamp,
  symbol,
  fetched_at
FROM {{ source('raw', 'bronze_stock_quotes_raw') }}
