{{ config(
    materialized='table',
    schema='gold'
) }}

-- 1) Source từ Silver (đã clean)
WITH source AS (
    SELECT
        symbol,
        SAFE_CAST(current_price AS FLOAT64) AS price,
        market_time_us,       -- timestamp theo giờ Mỹ
        market_time_utc
    FROM {{ ref('silver_stock_quotes') }}
    WHERE SAFE_CAST(current_price AS FLOAT64) IS NOT NULL
),

-- 2) Lấy ngày mới nhất theo giờ Mỹ
latest_day AS (
    SELECT
        MAX(CAST(market_time_us AS DATE)) AS max_day
    FROM source
),

-- 3) Giá trung bình theo ngày mới nhất
latest_avg_price AS (
    SELECT
        s.symbol,
        AVG(s.price) AS avg_price
    FROM source s
    JOIN latest_day ld
      ON CAST(s.market_time_us AS DATE) = ld.max_day
    GROUP BY s.symbol
),

-- 4) Biến động toàn thời gian
volatility AS (
    SELECT
        symbol,
        STDDEV_POP(price) AS volatility,
        CASE
            WHEN AVG(price) = 0 THEN NULL
            ELSE STDDEV_POP(price) / NULLIF(AVG(price), 0)
        END AS relative_volatility
    FROM source
    GROUP BY symbol
)

-- 5) Join để tạo bảng Treechart
SELECT
    a.symbol,
    a.avg_price,
    v.volatility,   
    v.relative_volatility
FROM latest_avg_price a
JOIN volatility v USING(symbol)
ORDER BY symbol
