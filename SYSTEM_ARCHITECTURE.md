# Phân Tích Cấu Trúc Hệ Thống Real-Time Stock Analytics

## 📋 Tổng Quan

Hệ thống này là một **pipeline xử lý dữ liệu real-time** cho việc thu thập, lưu trữ và phân tích dữ liệu chứng khoán từ API Finnhub. Hệ thống sử dụng kiến trúc **event-driven** với Kafka làm message broker và áp dụng mô hình **Medallion Architecture** (Bronze-Silver-Gold) cho data warehouse.

---

## 🏗️ Kiến Trúc Tổng Thể

```
┌─────────────┐
│  Finnhub    │  (External API)
│    API      │
└──────┬──────┘
       │ HTTP Request (mỗi 6 giây)
       ▼
┌─────────────────┐
│   Producer      │  (Python - Kafka Producer)
│  producer.py    │
└──────┬──────────┘
       │ Kafka Message
       ▼
┌─────────────────┐
│     Kafka       │  (Message Broker)
│  Topic: stock-  │
│     quotes      │
└──────┬──────────┘
       │ Consume
       ▼
┌─────────────────┐
│   Consumer      │  (Python - Kafka Consumer)
│  consumer.py    │
└──────┬──────────┘
       │ JSON Files
       ▼
┌─────────────────┐
│     MinIO       │  (Object Storage - S3 Compatible)
│ bronze-trans-   │
│   actions/      │
│ {symbol}/{ts}.  │
│     json        │
└──────┬──────────┘
       │ Airflow DAG (mỗi 1 phút)
       ▼
┌─────────────────┐
│   Apache        │  (Workflow Orchestration)
│   Airflow       │
│  DAG: minio_to_ │
│  bigquery_multi │
└──────┬──────────┘
       │ Incremental Load
       ▼
┌─────────────────┐
│   BigQuery      │  (Data Warehouse)
│  Dataset: stock │
│  - bronze_      │
│    stock_quotes │
│    _raw         │
└──────┬──────────┘
       │ dbt Transform
       ▼
┌─────────────────┐
│      dbt        │  (Data Transformation)
│  dbt_stocks/    │
│  Bronze → Silver│
│  → Gold         │
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│   BigQuery      │  (Analytics Layer)
│  - silver_      │
│    stock_quotes │
│  - gold_kpi     │
│  - gold_candle- │
│    stick        │
└─────────────────┘
```

---

## 🔧 Các Thành Phần Chính

### 1. **Data Ingestion Layer**

#### 1.1 Producer (`infra/producer/producer.py`)
- **Chức năng**: Thu thập dữ liệu real-time từ Finnhub API
- **Công nghệ**: Python, Kafka Producer, Requests
- **Hoạt động**:
  - Fetch quote cho 5 symbols: AAPL, MSFT, TSLA, GOOGL, AMZN
  - Gửi message vào Kafka topic `stock-quotes` mỗi 6 giây
  - Format: JSON với các field: `c`, `d`, `dp`, `h`, `l`, `o`, `pc`, `t`, `symbol`, `fetched_at`

#### 1.2 Consumer (`infra/consumer/consumer.py`)
- **Chức năng**: Consume messages từ Kafka và lưu vào MinIO
- **Công nghệ**: Python, Kafka Consumer, Boto3 (S3 API)
- **Hoạt động**:
  - Consume từ topic `stock-quotes`
  - Lưu file JSON vào MinIO bucket `bronze-transactions`
  - Cấu trúc key: `{symbol}/{timestamp}.json`
  - Group ID: `bronze-Consumer` (đảm bảo không mất message)

---

### 2. **Infrastructure Layer (Docker Compose)**

#### 2.1 Services Containerized

**Kafka Ecosystem:**
- **Zookeeper**: Quản lý metadata và coordination cho Kafka
- **Kafka**: Message broker (ports: 9092, 29092)
- **Kafdrop**: Web UI để monitor Kafka topics (port: 9000)

**Storage:**
- **MinIO**: S3-compatible object storage
  - Console: port 9001
  - API: port 9002
  - Credentials: admin/password123

**Orchestration:**
- **PostgreSQL**: Metadata database cho Airflow
- **Airflow Webserver**: Web UI (port: 8080)
- **Airflow Scheduler**: Chạy DAGs theo schedule
- **Airflow Init**: Khởi tạo database và admin user

**Monitoring:**
- **Grafana**: Dashboard và visualization (port: 3000)

---

### 3. **Data Pipeline Layer (Airflow)**

#### 3.1 DAG: `minio_to_bigquery_multi`
- **Schedule**: Mỗi 1 phút (`* * * * *`)
- **Chức năng**: Incremental load từ MinIO vào BigQuery

**Tasks cho mỗi symbol:**
1. **`download_{symbol}`**: 
   - Download chỉ các file mới từ MinIO (dựa trên `last_ts` trong metadata table)
   - Sử dụng pagination để xử lý >1000 objects
   - Sort files theo timestamp để tránh out-of-order
   - Push danh sách files và max_ts vào XCom

2. **`load_{symbol}`**:
   - Load JSON files vào BigQuery table `bronze_stock_quotes_raw`
   - Sử dụng `insert_rows_json` để batch insert
   - Update metadata table `metadata_last_ts` sau khi load thành công

**Tính năng quan trọng:**
- **Incremental loading**: Chỉ load files mới dựa trên timestamp
- **Metadata tracking**: Lưu `last_ts` để tránh duplicate
- **Parallel processing**: Xử lý 5 symbols song song
- **Error handling**: Retry logic và error logging

---

### 4. **Data Warehouse Layer (BigQuery)**

#### 4.1 Project & Dataset
- **Project**: `real-time-stock-analytics-25`
- **Dataset**: `stock`
- **Tables**:
  - `bronze_stock_quotes_raw`: Raw data từ MinIO
  - `metadata_last_ts`: Tracking metadata cho incremental load

---

### 5. **Data Transformation Layer (dbt)**

#### 5.1 Mô hình Medallion Architecture

**Bronze Layer** (`dbt_stocks/models/bronze/`)
- **`bronze_stock_quotes.sql`**: 
  - Materialized: `view`
  - Rename columns từ raw format (c, d, dp, h, l, o, pc, t) sang tên có ý nghĩa
  - Schema: `bronze`

**Silver Layer** (`dbt_stocks/models/silver/`)
- **`silver_stock_quotes.sql`**:
  - Materialized: `incremental` (merge strategy)
  - Data quality: Type casting, validation (price > 0, high >= low)
  - Deduplication: ROW_NUMBER() để loại bỏ duplicate
  - Timestamp conversion: Epoch seconds → TIMESTAMP (UTC & US timezone)
  - Unique key: `[symbol, market_timestamp_raw]`
  - Incremental filter: Chỉ load records chưa có trong Silver

**Gold Layer** (`dbt_stocks/models/gold/`)

1. **`gold_kpi.sql`**:
   - Materialized: `table`
   - Latest KPI cho mỗi symbol (ROW_NUMBER() ORDER BY fetched_at DESC)
   - Columns: current_price, change_amount, change_percent, day_open, day_high, day_low, prev_close

2. **`gold_kpi_latest.sql`**:
   - Materialized: `view`
   - Latest KPI từ history table (dựa trên market_time_utc)

3. **`gold_kpi_history.sql`**:
   - Materialized: `incremental` (merge strategy)
   - Lưu toàn bộ lịch sử KPI theo thời gian
   - Unique key: `[symbol, market_time_utc]`

4. **`gold_candlestick.sql`**:
   - Materialized: `table`
   - Aggregate dữ liệu thành candlestick chart (OHLC) theo ngày
   - Window functions để tính OPEN (first value) và CLOSE (last value)
   - Lấy 12 ngày gần nhất cho mỗi symbol
   - Columns: candle_date, candle_open, candle_high, candle_low, candle_close, trend_line

5. **`gold_treechart.sql`**:
   - Materialized: `table`
   - Tính toán volatility và average price cho visualization dạng tree chart
   - Lấy giá trung bình của ngày mới nhất
   - Tính volatility (standard deviation) và relative volatility
   - Columns: symbol, avg_price, volatility, relative_volatility

---

## 📊 Data Flow Chi Tiết

### Real-Time Flow (6 giây/lần)
```
Finnhub API → Producer → Kafka → Consumer → MinIO
```

### Batch Processing Flow (1 phút/lần)
```
MinIO → Airflow DAG → BigQuery Bronze → dbt Silver → dbt Gold
```

### Data Transformation Flow
```
Raw JSON (MinIO)
    ↓
Bronze (BigQuery - View)
    ↓ Rename columns
Silver (BigQuery - Incremental Table)
    ↓ Type casting, validation, deduplication
Gold (BigQuery - Tables/Views)
    ↓ Aggregation, KPI calculation
Analytics & Dashboards
```

---

## 🔐 Configuration & Credentials

### MinIO
- Endpoint: `http://minio:9000` (internal), `http://localhost:9002` (external)
- Access Key: `admin`
- Secret Key: `password123`
- Bucket: `bronze-transactions`

### Kafka
- Bootstrap Servers: `localhost:29092` (external), `kafka:9092` (internal)
- Topic: `stock-quotes`
- Consumer Group: `bronze-Consumer`

### BigQuery
- Project: `real-time-stock-analytics-25`
- Dataset: `stock`
- Credentials: `infra/airflow_gcp_key.json` (mounted vào Airflow containers)

### Finnhub API
- API Key: `d4139g9r01qr2l0cd2v0d4139g9r01qr2l0cd2vg`
- Endpoint: `https://finnhub.io/api/v1/quote`
- Rate Limit: 60 calls/minute (5 symbols × 12 calls/min = 60)

---

## 📁 Cấu Trúc Thư Mục

```
real-time-stock/
├── infra/                          # Infrastructure code
│   ├── dags/                       # Airflow DAGs
│   │   └── minio_to_bigquery_multi.py
│   ├── producer/                   # Kafka Producer
│   │   └── producer.py
│   ├── consumer/                   # Kafka Consumer
│   │   └── consumer.py
│   ├── docker-compose.yml          # Container orchestration
│   ├── Dockerfile                  # Custom Airflow image
│   ├── requirements.txt            # Python dependencies
│   └── airflow_gcp_key.json        # GCP credentials
│
├── dbt_stocks/                     # dbt project
│   ├── models/
│   │   ├── bronze/                 # Bronze layer
│   │   │   ├── bronze_stock_quotes.sql
│   │   │   └── sources.yml
│   │   ├── silver/                 # Silver layer
│   │   │   └── silver_stock_quotes.sql
│   │   └── gold/                   # Gold layer
│   │       ├── gold_kpi.sql
│   │       ├── gold_kpi_latest.sql
│   │       ├── gold_kpi_history.sql
│   │       ├── gold_candlestick.sql
│   │       └── gold_treechart.sql
│   ├── dbt_project.yml             # dbt configuration
│   └── README.md
│
├── requirements.txt                # Root dependencies
├── logs/                           # Application logs
└── venv312/                        # Python virtual environment
```

---

## 🎯 Điểm Mạnh của Hệ Thống

1. **Scalability**: 
   - Kafka cho phép scale consumer/producer độc lập
   - Airflow DAG xử lý parallel cho nhiều symbols
   - BigQuery tự động scale theo workload

2. **Reliability**:
   - Kafka đảm bảo message không bị mất
   - Incremental loading với metadata tracking
   - Retry logic trong Airflow

3. **Data Quality**:
   - Validation ở Silver layer
   - Deduplication logic
   - Type casting và normalization

4. **Separation of Concerns**:
   - Medallion Architecture (Bronze-Silver-Gold)
   - Clear separation giữa ingestion, storage, transformation

5. **Monitoring**:
   - Kafdrop cho Kafka monitoring
   - Airflow UI cho pipeline monitoring
   - Grafana cho visualization

---

## 🔄 Workflow Execution

### 1. Producer (Chạy liên tục)
```bash
python infra/producer/producer.py
```
- Fetch data mỗi 6 giây
- Gửi vào Kafka topic

### 2. Consumer (Chạy liên tục)
```bash
python infra/consumer/consumer.py
```
- Consume từ Kafka
- Lưu vào MinIO

### 3. Airflow (Tự động chạy)
- Scheduler chạy DAG mỗi 1 phút
- Download và load incremental data

### 4. dbt (Chạy thủ công hoặc schedule)
```bash
cd dbt_stocks
dbt run
```
- Transform Bronze → Silver → Gold

---

## 📈 Performance Characteristics

- **Latency**: 
  - Real-time ingestion: ~6 giây
  - Batch processing: ~1 phút
  - End-to-end: ~1-2 phút từ API đến Gold layer

- **Throughput**:
  - 5 symbols × 10 messages/phút = 50 messages/phút
  - ~3000 messages/giờ
  - ~72,000 messages/ngày

- **Storage**:
  - MinIO: JSON files (temporary storage)
  - BigQuery: Compressed columnar storage (long-term)

---

## 🛠️ Technologies Stack

| Layer | Technology |
|-------|-----------|
| Message Broker | Apache Kafka |
| Object Storage | MinIO (S3-compatible) |
| Orchestration | Apache Airflow |
| Data Warehouse | Google BigQuery |
| Transformation | dbt (Data Build Tool) |
| Monitoring | Kafdrop, Grafana |
| Database | PostgreSQL (Airflow metadata) |
| Language | Python 3.12 |

---

## 🔍 Monitoring & Observability

1. **Kafdrop** (http://localhost:9000): Monitor Kafka topics, messages, consumer groups
2. **Airflow UI** (http://localhost:8080): Monitor DAG runs, task status, logs
3. **Grafana** (http://localhost:3000): Custom dashboards và metrics
4. **BigQuery Console**: Query performance, storage usage

---

## 🚀 Deployment

Hệ thống được containerized hoàn toàn với Docker Compose:
```bash
cd infra
docker-compose up -d
```

Services sẽ tự động start theo thứ tự dependencies.

---

## 📝 Notes

- Hệ thống đang chạy ổn định với pipeline real-time
- Incremental loading giúp tối ưu performance và cost
- Medallion Architecture đảm bảo data quality và traceability
- Có thể scale bằng cách thêm symbols hoặc tăng frequency

