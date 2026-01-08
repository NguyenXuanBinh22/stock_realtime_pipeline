# Phân Tích Chi Tiết Kiến Trúc Hệ Thống Real-Time Stock Analytics

## 📑 Mục Lục

1. [Tổng Quan Hệ Thống](#1-tổng-quan-hệ-thống)
2. [Kiến Trúc Tổng Thể](#2-kiến-trúc-tổng-thể)
3. [Phân Tích Chi Tiết Từng Layer](#3-phân-tích-chi-tiết-từng-layer)
4. [Data Flow & Processing Patterns](#4-data-flow--processing-patterns)
5. [Infrastructure & Deployment](#5-infrastructure--deployment)
6. [Design Patterns & Best Practices](#6-design-patterns--best-practices)

---

## 1. Tổng Quan Hệ Thống

### 1.1 Mục Đích Hệ Thống

Hệ thống được thiết kế để:
- **Thu thập real-time**: Lấy dữ liệu chứng khoán từ Finnhub API mỗi 6 giây
- **Xử lý streaming**: Sử dụng Kafka để xử lý messages real-time
- **Lưu trữ phân tầng**: Áp dụng Medallion Architecture (Bronze-Silver-Gold)
- **Phân tích dữ liệu**: Tạo các metrics và KPIs cho dashboard

### 1.2 Kiến Trúc Tổng Thể

Hệ thống tuân theo **kiến trúc event-driven** với các đặc điểm:

```
┌─────────────────────────────────────────────────────────────┐
│                    EXTERNAL DATA SOURCE                     │
│                    (Finnhub API)                            │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              DATA INGESTION LAYER                           │
│  ┌──────────────┐         ┌──────────────┐                 │
│  │  Producer    │────────▶│    Kafka     │                 │
│  │  (Python)    │         │  (Broker)    │                 │
│  └──────────────┘         └──────┬───────┘                 │
│                                  │                          │
│                                  ▼                          │
│                          ┌──────────────┐                   │
│                          │   Consumer   │                   │
│                          │   (Python)   │                   │
│                          └──────┬───────┘                   │
└─────────────────────────────────┼───────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────┐
│              STORAGE LAYER                                  │
│  ┌──────────────┐         ┌──────────────┐                 │
│  │    MinIO     │────────▶│  BigQuery    │                 │
│  │  (S3-like)   │         │  (Bronze)    │                 │
│  └──────────────┘         └──────────────┘                 │
└─────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────┐
│         TRANSFORMATION LAYER (dbt)                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │   Bronze     │─▶│   Silver     │─▶│    Gold      │     │
│  │   (View)     │  │  (Incremental)│  │   (Tables)   │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
└─────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────┐
│              ANALYTICS & VISUALIZATION                      │
│         (BigQuery Gold Tables + Dashboards)                 │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 Technology Stack

| Category | Technology | Version/Purpose |
|----------|-----------|-----------------|
| **Message Broker** | Apache Kafka | 7.4.1 - Event streaming |
| **Coordination** | Apache Zookeeper | 7.4.1 - Kafka coordination |
| **Object Storage** | MinIO | Latest - S3-compatible storage |
| **Orchestration** | Apache Airflow | 2.9.3 - Workflow management |
| **Database** | PostgreSQL | 15 - Airflow metadata |
| **Data Warehouse** | Google BigQuery | Cloud - Analytics engine |
| **Transformation** | dbt | Latest - SQL transformation |
| **Monitoring** | Kafdrop, Grafana | Latest - Observability |
| **Language** | Python | 3.12 - Application code |

---

## 2. Kiến Trúc Tổng Thể

### 2.1 High-Level Architecture

Hệ thống được chia thành **5 tầng chính**:

#### **Tầng 1: Data Ingestion (Real-Time)**
- **Producer**: Fetch data từ API và publish vào Kafka
- **Kafka**: Message broker với topic `stock-quotes`
- **Consumer**: Consume messages và lưu vào MinIO

#### **Tầng 2: Batch Processing (Scheduled)**
- **Airflow DAG**: Chạy mỗi 1 phút để load incremental data
- **MinIO → BigQuery**: ETL process với metadata tracking

#### **Tầng 3: Data Warehouse (Bronze)**
- **BigQuery Raw Tables**: Lưu trữ dữ liệu thô
- **Metadata Table**: Track last processed timestamp

#### **Tầng 4: Data Transformation (Silver & Gold)**
- **dbt Bronze**: View để rename columns
- **dbt Silver**: Incremental table với validation
- **dbt Gold**: Aggregated tables cho analytics

#### **Tầng 5: Analytics & Consumption**
- **Gold Tables**: KPI, candlestick, history
- **Dashboards**: Visualization tools

### 2.2 Data Flow Patterns

#### **Pattern 1: Real-Time Streaming (6 giây)**
```
Finnhub API 
  → Producer (fetch_quote)
  → Kafka Topic (stock-quotes)
  → Consumer (consume & save)
  → MinIO (bronze-transactions/{symbol}/{ts}.json)
```

**Đặc điểm:**
- **Latency**: ~6 giây end-to-end
- **Throughput**: 5 symbols × 10 calls/min = 50 messages/phút
- **Reliability**: Kafka đảm bảo message không mất (consumer group)

#### **Pattern 2: Batch Processing (1 phút)**
```
MinIO (new files)
  → Airflow DAG (download_from_minio)
  → Local temp storage
  → Airflow DAG (load_bigquery)
  → BigQuery Bronze (bronze_stock_quotes_raw)
  → Metadata update (metadata_last_ts)
```

**Đặc điểm:**
- **Incremental**: Chỉ load files mới (dựa trên timestamp)
- **Parallel**: Xử lý 5 symbols song song
- **Idempotent**: Metadata tracking tránh duplicate

#### **Pattern 3: Data Transformation (On-demand hoặc scheduled)**
```
BigQuery Bronze (raw)
  → dbt Bronze (view - rename)
  → dbt Silver (incremental - validate & dedupe)
  → dbt Gold (tables - aggregate)
```

**Đặc điểm:**
- **Incremental Strategy**: Merge cho Silver và Gold
- **Data Quality**: Validation ở Silver layer
- **Performance**: Chỉ transform dữ liệu mới

---

## 3. Phân Tích Chi Tiết Từng Layer

### 3.1 Data Ingestion Layer

#### 3.1.1 Producer Component

**File**: `infra/producer/producer.py`

**Chức năng:**
```python
# 1. Khởi tạo Kafka Producer
producer = KafkaProducer(
    bootstrap_servers=["localhost:29092"],
    value_serializer=lambda v: json.dumps(v).encode("utf-8")
)

# 2. Fetch data từ API
def fetch_quote(symbol):
    url = f"{BASE_URL}?symbol={symbol}&token={API_KEY}"
    response = requests.get(url)
    data = response.json()
    data["symbol"] = symbol
    data["fetched_at"] = int(time.time())  # Thêm timestamp
    return data

# 3. Loop và publish
while True:
    for symbol in SYMBOLS:
        quote = fetch_quote(symbol)
        producer.send("stock-quotes", value=quote)
    time.sleep(6)  # Rate limiting
```

**Phân tích:**

1. **Serialization**: 
   - Python dict → JSON string → UTF-8 bytes
   - Kafka lưu dưới dạng binary

2. **Rate Limiting**:
   - 5 symbols × 10 calls/min = 50 calls/min
   - Finnhub limit: 60 calls/min
   - Sleep 6 giây giữa các batch

3. **Error Handling**:
   - Try-catch trong `fetch_quote()`
   - Continue nếu một symbol fail

4. **Data Enrichment**:
   - Thêm `symbol` vào response
   - Thêm `fetched_at` (epoch timestamp)

**Message Format:**
```json
{
  "c": 150.25,           // current price
  "d": 2.50,             // change amount
  "dp": 1.69,            // change percent
  "h": 152.00,           // day high
  "l": 148.50,           // day low
  "o": 149.00,           // day open
  "pc": 147.75,          // previous close
  "t": 1704067200,       // market timestamp (epoch)
  "symbol": "AAPL",      // added by producer
  "fetched_at": 1704067256  // added by producer
}
```

#### 3.1.2 Kafka Infrastructure

**Configuration** (`docker-compose.yml`):

```yaml
kafka:
  image: confluentinc/cp-kafka:7.4.1
  environment:
    KAFKA_BROKER_ID: 1
    KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
    KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,PLAINTEXT_HOST://0.0.0.0:29092
    KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092,PLAINTEXT_HOST://localhost:29092
    KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
```

**Phân tích:**

1. **Listeners**:
   - `PLAINTEXT://0.0.0.0:9092`: Internal (container-to-container)
   - `PLAINTEXT_HOST://0.0.0.0:29092`: External (host-to-container)

2. **Replication**:
   - `REPLICATION_FACTOR: 1`: Single broker (dev environment)
   - Production nên dùng >= 3

3. **Topic**: `stock-quotes`
   - Partitions: Default (có thể scale)
   - Retention: Default (7 days)

#### 3.1.3 Consumer Component

**File**: `infra/consumer/consumer.py`

**Chức năng:**
```python
# 1. Khởi tạo MinIO client
s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:9002",
    aws_access_key_id="admin",
    aws_secret_access_key="password123"
)

# 2. Khởi tạo Kafka Consumer
consumer = KafkaConsumer(
    "stock-quotes",
    bootstrap_servers=["localhost:29092"],
    enable_auto_commit=True,
    auto_offset_reset="earliest",
    group_id="bronze-Consumer",
    value_deserializer=lambda v: json.loads(v.decode("utf-8"))
)

# 3. Consume và save
for message in consumer:
    record = message.value
    symbol = record.get("symbol")
    ts = record.get("fetched_at", int(time.time()))
    key = f"{symbol}/{ts}.json"
    
    s3.put_object(
        Bucket="bronze-transactions",
        Key=key,
        Body=json.dumps(record),
        ContentType="application/json"
    )
```

**Phân tích:**

1. **Consumer Group**: `bronze-Consumer`
   - Đảm bảo mỗi message chỉ được consume 1 lần
   - Auto-commit offset sau khi process

2. **Offset Management**:
   - `auto_offset_reset="earliest"`: Đọc từ đầu nếu chưa có offset
   - `enable_auto_commit=True`: Tự động commit sau khi process

3. **Storage Strategy**:
   - Key pattern: `{symbol}/{timestamp}.json`
   - Partitioned by symbol (dễ query theo symbol)
   - Timestamp-based naming (dễ sort và filter)

4. **Idempotency**:
   - Mỗi message tạo 1 file unique (symbol + timestamp)
   - Không có risk duplicate nếu consumer restart

### 3.2 Storage Layer

#### 3.2.1 MinIO Configuration

**Docker Compose:**
```yaml
minio:
  image: minio/minio:latest
  ports:
    - "9001:9001"  # Console UI
    - "9002:9000"  # S3 API
  environment:
    MINIO_ROOT_USER: admin
    MINIO_ROOT_PASSWORD: password123
  command: server /data --console-address ":9001"
  volumes:
    - minio_data:/data
```

**Phân tích:**

1. **S3-Compatible API**:
   - Sử dụng Boto3 (AWS SDK)
   - Tương thích 100% với S3 API
   - Có thể migrate sang AWS S3 dễ dàng

2. **Storage Structure**:
   ```
   bronze-transactions/
   ├── AAPL/
   │   ├── 1704067200.json
   │   ├── 1704067260.json
   │   └── ...
   ├── MSFT/
   │   └── ...
   └── ...
   ```

3. **Use Case**:
   - **Temporary storage**: Lưu raw data trước khi load vào BigQuery
   - **Backup**: Có thể giữ lại để replay nếu cần
   - **Buffering**: Decouple Kafka consumer và BigQuery loader

#### 3.2.2 BigQuery Bronze Layer

**Table Schema**: `bronze_stock_quotes_raw`

**Structure** (từ JSON):
```sql
CREATE TABLE `real-time-stock-analytics-25.stock.bronze_stock_quotes_raw` (
  c FLOAT64,           -- current_price
  d FLOAT64,           -- change_amount
  dp FLOAT64,          -- change_percent
  h FLOAT64,           -- day_high
  l FLOAT64,           -- day_low
  o FLOAT64,           -- day_open
  pc FLOAT64,          -- prev_close
  t INT64,             -- market_timestamp
  symbol STRING,       -- stock symbol
  fetched_at INT64     -- fetch timestamp
)
```

**Metadata Table**: `metadata_last_ts`
```sql
CREATE TABLE `real-time-stock-analytics-25.stock.metadata_last_ts` (
  symbol STRING,
  last_ts INT64
)
```

**Phân tích:**

1. **Incremental Loading Strategy**:
   ```python
   # 1. Đọc last_ts từ metadata
   last_ts = get_last_ts(symbol)  # Query BigQuery
   
   # 2. Filter files mới hơn last_ts
   if ts > last_ts:
       download_and_load()
   
   # 3. Update metadata sau khi load
   update_last_ts(symbol, max_ts)
   ```

2. **MERGE Statement** (idempotent):
   ```sql
   MERGE `metadata_last_ts` T
   USING (SELECT 'AAPL' AS symbol, 1704067260 AS last_ts) S
   ON T.symbol = S.symbol
   WHEN MATCHED THEN UPDATE SET last_ts = S.last_ts
   WHEN NOT MATCHED THEN INSERT (symbol, last_ts) VALUES (S.symbol, S.last_ts)
   ```

3. **Pagination Handling**:
   ```python
   def list_all_objects(s3, bucket, prefix):
       objects = []
       token = None
       while True:
           if token:
               resp = s3.list_objects_v2(..., ContinuationToken=token)
           else:
               resp = s3.list_objects_v2(...)
           objects.extend(resp.get("Contents", []))
           if not resp.get("IsTruncated"):
               break
           token = resp["NextContinuationToken"]
       return objects
   ```
   - S3 API chỉ trả về tối đa 1000 objects/lần
   - Cần pagination với `ContinuationToken`

### 3.3 Transformation Layer (dbt)

#### 3.3.1 Bronze Layer

**File**: `dbt_stocks/models/bronze/bronze_stock_quotes.sql`

```sql
{{ config(
    materialized = 'view',
    schema = 'bronze'
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
```

**Phân tích:**

1. **Materialization: VIEW**
   - Không lưu trữ dữ liệu
   - Chỉ là SQL transformation
   - Real-time query từ raw table

2. **Column Renaming**:
   - Từ tên ngắn (c, d, dp) → tên có ý nghĩa
   - Dễ đọc và maintain

3. **Source Definition** (`sources.yml`):
   ```yaml
   sources:
     - name: raw
       database: real-time-stock-analytics-25
       schema: stock
       tables:
         - name: bronze_stock_quotes_raw
   ```

#### 3.3.2 Silver Layer

**File**: `dbt_stocks/models/silver/silver_stock_quotes.sql`

**Cấu trúc:**

```sql
{{ config(
    materialized = 'incremental',
    schema = 'silver',
    unique_key = ['symbol', 'market_timestamp_raw'],
    incremental_strategy = 'merge'
) }}

WITH base AS (
    -- Type casting
    SELECT
        symbol,
        CAST(current_price AS FLOAT64) AS current_price,
        CAST(market_timestamp AS INT64) AS market_timestamp_raw,
        TIMESTAMP_SECONDS(CAST(market_timestamp AS INT64)) AS market_time_utc,
        DATETIME(TIMESTAMP_SECONDS(...), "America/New_York") AS market_time_us,
        TIMESTAMP_SECONDS(CAST(fetched_at AS INT64)) AS fetched_at
    FROM {{ ref('bronze_stock_quotes') }}
),

filtered AS (
    -- Incremental filter
    SELECT b.*
    FROM base b
    {% if is_incremental() %}
    LEFT JOIN {{ this }} s
      ON s.symbol = b.symbol
      AND s.market_timestamp_raw = b.market_timestamp_raw
    WHERE s.symbol IS NULL
    {% endif %}
),

dedup AS (
    -- Remove duplicates trong batch
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY symbol, market_timestamp_raw
            ORDER BY fetched_at DESC
        ) AS rn
    FROM filtered
),

validated AS (
    -- Data quality checks
    SELECT *
    FROM dedup
    WHERE rn = 1
      AND current_price > 0
      AND prev_close > 0
      AND day_open > 0
      AND day_high >= day_low
)

SELECT ... FROM validated
```

**Phân tích chi tiết:**

1. **Incremental Strategy: MERGE**
   - Chỉ process dữ liệu mới
   - `is_incremental()` macro kiểm tra lần chạy đầu tiên hay không
   - LEFT JOIN để filter records đã tồn tại

2. **Type Casting**:
   - String/Number → FLOAT64
   - Epoch seconds → TIMESTAMP
   - Timezone conversion (UTC → US Eastern)

3. **Deduplication**:
   - Window function `ROW_NUMBER()` partition by `(symbol, market_timestamp_raw)`
   - Order by `fetched_at DESC` (lấy bản mới nhất)
   - Filter `rn = 1`

4. **Data Validation**:
   - `current_price > 0`: Giá phải dương
   - `prev_close > 0`: Giá đóng cửa trước phải dương
   - `day_open > 0`: Giá mở cửa phải dương
   - `day_high >= day_low`: Logic check (high không thể < low)

5. **Performance**:
   - Incremental chỉ scan dữ liệu mới
   - MERGE statement hiệu quả hơn DELETE + INSERT
   - Index trên `unique_key` để tăng tốc JOIN

#### 3.3.3 Gold Layer

**5 Models chính:**

##### **1. gold_kpi.sql** (Latest KPI)
```sql
{{ config(materialized='table', schema='gold') }}

WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY symbol
            ORDER BY fetched_at DESC
        ) AS rn
    FROM {{ ref('silver_stock_quotes') }}
)
SELECT ... FROM ranked WHERE rn = 1
```

**Mục đích**: Lấy KPI mới nhất cho mỗi symbol (dựa trên `fetched_at`)

##### **2. gold_kpi_latest.sql** (View từ History)
```sql
{{ config(materialized='view', schema='gold') }}

WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY symbol
            ORDER BY market_time_utc DESC
        ) AS rn
    FROM {{ ref('gold_kpi_history') }}
)
SELECT ... FROM ranked WHERE rn = 1
```

**Mục đích**: Latest KPI từ history table (dựa trên `market_time_utc`)

##### **3. gold_kpi_history.sql** (Incremental History)
```sql
{{ config(
    materialized='incremental',
    schema='gold',
    unique_key=['symbol', 'market_time_utc'],
    incremental_strategy='merge'
) }}

-- Incremental filter tương tự Silver
```

**Mục đích**: Lưu toàn bộ lịch sử KPI theo thời gian

##### **4. gold_candlestick.sql** (OHLC Aggregation)
```sql
WITH enriched AS (
    SELECT
        symbol,
        CAST(market_time_us AS DATE) AS candle_date,
        -- Window functions để tính OPEN và CLOSE
        FIRST_VALUE(current_price) OVER (
            PARTITION BY symbol, CAST(market_time_us AS DATE)
            ORDER BY market_time_us
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ) AS candle_open,
        LAST_VALUE(current_price) OVER (...) AS candle_close
    FROM {{ ref('silver_stock_quotes') }}
),
daily AS (
    SELECT
        symbol,
        candle_date,
        MIN(day_low) AS candle_low,
        MAX(day_high) AS candle_high,
        ANY_VALUE(candle_open) AS candle_open,
        ANY_VALUE(candle_close) AS candle_close,
        AVG(current_price) AS trend_line
    FROM enriched
    GROUP BY symbol, candle_date
),
ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY symbol
            ORDER BY candle_date DESC
        ) AS rn
    FROM daily
)
SELECT ... FROM ranked WHERE rn <= 12
```

**Phân tích:**

1. **Window Functions**:
   - `FIRST_VALUE()`: Giá đầu tiên trong ngày (OPEN)
   - `LAST_VALUE()`: Giá cuối cùng trong ngày (CLOSE)
   - `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`: Toàn bộ partition

2. **Aggregation**:
   - `MIN(day_low)`: Low của ngày
   - `MAX(day_high)`: High của ngày
   - `AVG(current_price)`: Trend line

3. **Filtering**:
   - Chỉ lấy 12 ngày gần nhất (`rn <= 12`)
   - Đủ để hiển thị candlestick chart

##### **5. gold_treechart.sql** (Volatility Analysis)
```sql
WITH source AS (
    SELECT symbol, current_price AS price, market_time_us
    FROM {{ ref('silver_stock_quotes') }}
),
latest_day AS (
    SELECT MAX(CAST(market_time_us AS DATE)) AS max_day
    FROM source
),
latest_avg_price AS (
    SELECT symbol, AVG(price) AS avg_price
    FROM source s
    JOIN latest_day ld ON CAST(s.market_time_us AS DATE) = ld.max_day
    GROUP BY symbol
),
volatility AS (
    SELECT
        symbol,
        STDDEV_POP(price) AS volatility,
        STDDEV_POP(price) / NULLIF(AVG(price), 0) AS relative_volatility
    FROM source
    GROUP BY symbol
)
SELECT a.symbol, a.avg_price, v.volatility, v.relative_volatility
FROM latest_avg_price a
JOIN volatility v USING(symbol)
```

**Phân tích:**

1. **Volatility Calculation**:
   - `STDDEV_POP()`: Population standard deviation
   - `relative_volatility`: Volatility / Average price (normalized)

2. **Latest Day Average**:
   - Lấy giá trung bình của ngày mới nhất
   - Dùng cho tree chart visualization

### 3.4 Orchestration Layer (Airflow)

#### 3.4.1 DAG Structure

**File**: `infra/dags/minio_to_bigquery_multi.py`

```python
with DAG(
    dag_id="minio_to_bigquery_multi",
    schedule_interval="* * * * *",  # Every 1 minute
    catchup=False,
) as dag:
    
    for symbol in SYMBOLS:
        t1 = PythonOperator(
            task_id=f"download_{symbol}",
            python_callable=download_from_minio,
            op_kwargs={"symbol": symbol},
        )
        
        t2 = PythonOperator(
            task_id=f"load_{symbol}",
            python_callable=load_bigquery,
            op_kwargs={"symbol": symbol},
        )
        
        t1 >> t2  # Sequential dependency
```

**Task Graph:**
```
download_AAPL ──▶ load_AAPL
download_MSFT ──▶ load_MSFT
download_TSLA ──▶ load_TSLA
download_GOOGL ──▶ load_GOOGL
download_AMZN ──▶ load_AMZN
```

**Phân tích:**

1. **Parallel Execution**:
   - 5 symbols chạy song song (không phụ thuộc nhau)
   - Airflow scheduler tự động parallelize

2. **Sequential per Symbol**:
   - `download_{symbol}` phải hoàn thành trước `load_{symbol}`
   - XCom truyền danh sách files giữa tasks

3. **XCom Communication**:
   ```python
   # Task 1: Push data
   context["ti"].xcom_push(key=f"{symbol}_files", value=new_files)
   context["ti"].xcom_push(key=f"{symbol}_max_ts", value=max_ts)
   
   # Task 2: Pull data
   files = context["ti"].xcom_pull(key=f"{symbol}_files")
   max_ts = context["ti"].xcom_pull(key=f"{symbol}_max_ts")
   ```

4. **Error Handling**:
   ```python
   default_args = {
       "retries": 1,
       "retry_delay": timedelta(minutes=2),
   }
   ```
   - Retry 1 lần nếu fail
   - Delay 2 phút trước khi retry

#### 3.4.2 Airflow Infrastructure

**Docker Compose Configuration:**

```yaml
airflow-webserver:
  build: .
  image: airflow-custom:latest
  environment:
    GOOGLE_APPLICATION_CREDENTIALS: /opt/airflow/airflow_gcp_key.json
    GCP_PROJECT: "real-time-stock-analytics-25"
  volumes:
    - ./dags:/opt/airflow/dags
    - ./airflow_gcp_key.json:/opt/airflow/airflow_gcp_key.json

airflow-scheduler:
  image: airflow-custom:latest
  environment:
    GOOGLE_APPLICATION_CREDENTIALS: /opt/airflow/airflow_gcp_key.json
    GCP_PROJECT: "real-time-stock-analytics-25"
```

**Phân tích:**

1. **Custom Image**:
   - Build từ `apache/airflow:2.9.3`
   - Install thêm packages từ `requirements.txt`
   - BigQuery client libraries

2. **GCP Authentication**:
   - Mount service account key vào container
   - Set `GOOGLE_APPLICATION_CREDENTIALS` environment variable
   - BigQuery client tự động authenticate

3. **Volume Mounts**:
   - `./dags`: DAG files (hot reload)
   - `./logs`: Task logs
   - `./airflow_gcp_key.json`: GCP credentials

---

## 4. Data Flow & Processing Patterns

### 4.1 End-to-End Data Flow

#### **Timeline của một message:**

```
T=0s:    Producer fetch từ Finnhub API
T=0.1s:  Producer publish vào Kafka
T=0.2s:  Consumer consume từ Kafka
T=0.3s:  Consumer save vào MinIO (AAPL/1704067200.json)
T=60s:   Airflow DAG trigger (schedule)
T=60.1s: Airflow download file từ MinIO
T=60.2s: Airflow load vào BigQuery Bronze
T=60.3s: Airflow update metadata_last_ts
T=61s:   dbt run (nếu schedule hoặc manual)
T=61.1s: dbt Bronze view query
T=61.2s: dbt Silver incremental merge
T=61.3s: dbt Gold tables update
```

**Total Latency**: ~61-62 giây từ API đến Gold layer

### 4.2 Processing Patterns

#### **Pattern 1: Event-Driven (Real-Time)**
- **Trigger**: Producer fetch API mỗi 6 giây
- **Processing**: Asynchronous, non-blocking
- **Storage**: MinIO (temporary buffer)

#### **Pattern 2: Batch Processing (Scheduled)**
- **Trigger**: Cron schedule (`* * * * *`)
- **Processing**: Synchronous, sequential per symbol
- **Storage**: BigQuery (persistent)

#### **Pattern 3: Incremental Processing**
- **Strategy**: Timestamp-based filtering
- **Benefits**: 
  - Chỉ process dữ liệu mới
  - Giảm cost và latency
  - Idempotent (có thể retry)

#### **Pattern 4: Lambda Architecture**
- **Real-time path**: Kafka → MinIO (low latency)
- **Batch path**: MinIO → BigQuery (high accuracy)
- **Unified view**: dbt Gold layer

### 4.3 Data Consistency

#### **At-Least-Once Delivery**
- Kafka: Consumer group đảm bảo message được process
- MinIO: File-based storage (idempotent)
- BigQuery: MERGE statement (idempotent)

#### **Deduplication Strategy**
1. **Kafka Level**: Consumer group (mỗi message 1 lần)
2. **MinIO Level**: File naming (symbol + timestamp = unique)
3. **BigQuery Level**: 
   - Metadata tracking (timestamp-based)
   - dbt Silver: ROW_NUMBER() deduplication
   - dbt Gold: Unique key constraints

---

## 5. Infrastructure & Deployment

### 5.1 Container Architecture

**Services và Dependencies:**

```
postgres (Airflow metadata)
  ↑
  ├── airflow-init (one-time setup)
  ├── airflow-webserver
  └── airflow-scheduler

zookeeper
  ↑
  └── kafka
      ↑
      └── kafdrop

minio (standalone)

grafana (standalone)
```

### 5.2 Network Architecture

**Internal Network (Docker)**
- Services giao tiếp qua service names
- Example: `http://minio:9000`, `kafka:9092`

**External Access (Host)**
- Port mapping để access từ host
- Example: `localhost:29092`, `localhost:9002`

### 5.3 Storage Volumes

```yaml
volumes:
  postgres_data:    # Airflow metadata persistence
  minio_data:       # Object storage persistence
  grafana_data:     # Grafana dashboards persistence
```

**Phân tích:**
- Named volumes persist data khi container restart
- Data không bị mất khi `docker-compose down`

### 5.4 Deployment Process

**1. Build Custom Airflow Image:**
```bash
cd infra
docker build -t airflow-custom:latest .
```

**2. Start Services:**
```bash
docker-compose up -d
```

**3. Verify:**
- Airflow UI: http://localhost:8080
- Kafdrop: http://localhost:9000
- MinIO Console: http://localhost:9001
- Grafana: http://localhost:3000

**4. Run Producer & Consumer:**
```bash
# Terminal 1
python infra/producer/producer.py

# Terminal 2
python infra/consumer/consumer.py
```

**5. Run dbt:**
```bash
cd dbt_stocks
dbt run
```

---

## 6. Design Patterns & Best Practices

### 6.1 Medallion Architecture

**Bronze (Raw)**
- Purpose: Store raw data as-is
- Format: JSON files, raw tables
- No transformation

**Silver (Cleaned)**
- Purpose: Cleaned, validated, deduplicated data
- Format: Incremental tables
- Transformations: Type casting, validation, deduplication

**Gold (Curated)**
- Purpose: Business-ready analytics tables
- Format: Aggregated tables, views
- Transformations: Aggregations, KPIs, business logic

**Benefits:**
- Clear separation of concerns
- Easy to debug (trace data lineage)
- Flexible (có thể rebuild từ bất kỳ layer nào)

### 6.2 Incremental Processing

**Pattern:**
```python
# 1. Read checkpoint
last_ts = get_last_ts(symbol)

# 2. Filter new data
new_data = filter(lambda x: x.ts > last_ts, all_data)

# 3. Process new data
process(new_data)

# 4. Update checkpoint
update_last_ts(symbol, max_ts)
```

**Benefits:**
- Efficiency: Chỉ process dữ liệu mới
- Cost: Giảm compute và storage cost
- Scalability: Handle large datasets

### 6.3 Idempotency

**Strategy:**
1. **Unique Keys**: `(symbol, timestamp)` đảm bảo uniqueness
2. **MERGE Statements**: Upsert thay vì INSERT
3. **Metadata Tracking**: Track processed timestamps
4. **Deduplication**: ROW_NUMBER() trong dbt

**Benefits:**
- Safe to retry
- No duplicate data
- Consistent results

### 6.4 Error Handling

**Layers:**

1. **Producer**:
   ```python
   try:
       quote = fetch_quote(symbol)
   except Exception as e:
       print(f"Error: {e}")
       continue  # Skip và tiếp tục
   ```

2. **Consumer**:
   - Kafka auto-commit: Message được mark là processed
   - Nếu consumer crash, message sẽ được retry

3. **Airflow**:
   - Retry logic: `retries=1, retry_delay=2min`
   - Task failure → Airflow UI alert

4. **dbt**:
   - SQL errors → dbt logs
   - Incremental filter → Safe to rerun

### 6.5 Monitoring & Observability

**Tools:**

1. **Kafdrop**: 
   - Monitor Kafka topics
   - View messages
   - Check consumer lag

2. **Airflow UI**:
   - DAG runs status
   - Task logs
   - XCom values

3. **Grafana**:
   - Custom dashboards
   - Metrics visualization

4. **BigQuery Console**:
   - Query performance
   - Storage usage
   - Job history

### 6.6 Scalability Considerations

**Current Limitations:**
- Single Kafka broker (dev environment)
- Single Airflow scheduler
- No horizontal scaling

**Production Recommendations:**

1. **Kafka**:
   - Multi-broker cluster (3+ brokers)
   - Increase partitions
   - Replication factor >= 3

2. **Airflow**:
   - Celery executor (distributed)
   - Multiple workers
   - Redis/RabbitMQ as message broker

3. **BigQuery**:
   - Partition tables by date
   - Cluster by symbol
   - Use streaming inserts for real-time

4. **dbt**:
   - Parallel model execution
   - Incremental models (đã implement)
   - Materialized views cho frequently queried data

---

## 7. Kết Luận

### 7.1 Điểm Mạnh

1. **Architecture**: 
   - Event-driven + Batch processing
   - Medallion Architecture
   - Clear separation of concerns

2. **Reliability**:
   - Idempotent operations
   - Error handling
   - Metadata tracking

3. **Performance**:
   - Incremental processing
   - Parallel execution
   - Efficient data structures

4. **Maintainability**:
   - Modular design
   - Clear data lineage
   - Well-documented

### 7.2 Cải Thiện Tiềm Năng

1. **Real-Time Processing**:
   - Thêm Kafka Streams hoặc Flink
   - Real-time aggregation

2. **Data Quality**:
   - Great Expectations integration
   - Automated data quality checks

3. **Monitoring**:
   - Prometheus + Grafana
   - Alerting rules

4. **Testing**:
   - Unit tests cho Python code
   - dbt tests cho data quality

5. **Documentation**:
   - Data dictionary
   - API documentation
   - Runbooks

---

**Tài liệu này cung cấp phân tích chi tiết từ tổng quan đến implementation của hệ thống Real-Time Stock Analytics.**

