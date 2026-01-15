## Real-time Stock Analytics Platform

Project `real-time-stock` là một pipeline end-to-end để thu thập, lưu trữ, transform và trực quan hóa **giá cổ phiếu theo thời gian thực** bằng Kafka, MinIO, Airflow, BigQuery, dbt và Grafana.

- **Producer**: lấy giá cổ phiếu từ API Finnhub và đẩy vào Kafka.
- **Consumer**: đọc dữ liệu từ Kafka và lưu JSON vào MinIO (bronze layer).
- **Airflow DAG**: đọc file từ MinIO, load vào BigQuery, sau đó chạy dbt để tạo các bảng phân tích.
- **dbt**: tổ chức mô hình dữ liệu theo 3 layer `bronze` → `silver` → `gold`.
- **Grafana**: đọc dữ liệu từ BigQuery để vẽ dashboard giám sát realtime / near-realtime.

---

## Kiến trúc tổng quan

- **Streaming layer**:
  - `infra/producer/producer.py`: gọi Finnhub API (`/quote`) theo interval, cho các mã `AAPL, MSFT, TSLA, GOOGL, AMZN`, và publish vào Kafka topic `stock-quotes`.
  - `infra/consumer/consumer.py`: lắng nghe topic `stock-quotes`, nhận JSON, ghi xuống MinIO bucket `bronze-transactions` theo key `symbol/timestamp.json`.
- **Storage + Data Lake**:
  - **MinIO**: đóng vai trò S3-compatible data lake layer (bronze).
  - **BigQuery**: lưu dữ liệu raw và các bảng transform (silver/gold).
- **Orchestration**:
  - `infra/dags/minio_to_bigquery_multi.py`: Airflow DAG chạy mỗi phút:
    - Mỗi symbol: đọc file mới từ MinIO → load vào BigQuery table `bronze_stock_quotes_raw`.
    - Cập nhật bảng metadata `metadata_last_ts` để biết đã load tới timestamp nào cho từng symbol.
    - Chỉ khi có dữ liệu mới, DAG mới chạy `dbt run`.
- **Transform (dbt)**:
  - Project `dbt_stocks`:
    - `models/bronze`: bảng raw (`bronze_stock_quotes`).
    - `models/silver`: chuẩn hóa và enrich dữ liệu quote (`silver_stock_quotes`).
    - `models/gold`: tính toán KPI, giá trị OHLC, SMA, RSI, ATR, candlestick, tree chart, v.v.
- **Visualization**:
  - Thư mục `grafana_dashboards/` (nếu có JSON/dashboard export) dùng để import vào Grafana.

---

## Cấu trúc thư mục chính

- **`infra/`**: hạ tầng chạy local bằng Docker Compose.
  - `docker-compose.yml`: định nghĩa các service:
    - `zookeeper`, `kafka`
    - `kafdrop` (UI xem Kafka topic)
    - `minio`
    - `postgres` (metadata DB cho Airflow)
    - `airflow-init`, `airflow-webserver`, `airflow-scheduler`
    - `grafana`
  - `producer/producer.py`: Kafka producer lấy dữ liệu từ Finnhub.
  - `consumer/consumer.py`: Kafka consumer lưu record vào MinIO.
  - `dags/minio_to_bigquery_multi.py`: DAG Airflow đọc MinIO → BigQuery → dbt.
  - `requirements.txt`: dependency cho Airflow/infra image (MinIO, BigQuery, dbt-bigquery,...).
  - `Dockerfile`: build image `airflow-custom` dùng cho Airflow.
- **`dbt_stocks/`**: dbt project.
  - `dbt_project.yml`: config project, model-paths, schema cho `bronze/silver/gold`.
  - `models/bronze/*.sql`: layer raw.
  - `models/silver/*.sql`: layer cleaned / normalized.
  - `models/gold/*.sql`: layer báo cáo / KPI.
- **`dbt_profiles/`**:
  - `profiles.yml`: cấu hình dbt để connect BigQuery bằng service account.
- **`grafana_dashboards/`**:
  - Lưu JSON file dashboard (nếu có) để import vào Grafana.
- **`requirements.txt` (root)**:
  - Library Python cho producer/consumer/dbt Snowflake/BigQuery (tùy môi trường bạn dùng).

---

## Yêu cầu môi trường & dependency

- **Hệ thống**:
  - Docker & Docker Compose (bản mới).
  - Python 3.12 (nếu muốn chạy producer/consumer ngoài container).
- **Cloud**:
  - GCP project (ví dụ: `real-time-stock-analytics-25`).
  - BigQuery dataset `stock` (hoặc tên dataset bạn cấu hình lại).
  - Service account JSON key có quyền BigQuery (được mount vào Airflow).
- **API**:
  - Tài khoản Finnhub và API key.

### Python dependency (root)

File `requirements.txt` tại root (dùng cho producer/consumer, dbt local):

- `kafka-python`
- `boto3`
- `snowflake-connector-python` (nếu dùng Snowflake – có thể không cần nếu chỉ dùng BigQuery)
- `dbt-core`
- `dbt-snowflake` (tùy môi trường)
- `requests`

### Python dependency cho Airflow image

File `infra/requirements.txt`:

- `minio`
- `google-cloud-bigquery`
- `google-cloud-storage`
- `google-auth`
- `dbt-core`
- `dbt-bigquery`

---

## Cách chạy hệ thống

### 1. Chuẩn bị GCP Service Account Key

- Tạo service account trên GCP với quyền tối thiểu:
  - **BigQuery Data Editor**
  - **BigQuery Job User**
  - (Tùy chọn) quyền đọc / ghi GCS nếu bạn dùng thêm GCS.
- Tải file JSON key, đổi tên (ví dụ) `airflow_gcp_key.json`.
- Copy file này vào thư mục `infra/` (cùng cấp với `docker-compose.yml`).

Đảm bảo các biến sau trong `infra/docker-compose.yml` khớp với project của bạn:

- `GCP_PROJECT` (ví dụ: `real-time-stock-analytics-25`)
- Mount file:
  - `./airflow_gcp_key.json:/opt/airflow/airflow_gcp_key.json`
  - `./airflow_gcp_key.json:/opt/airflow/keys/airflow_gcp_key.json:ro`

### 2. Chuẩn bị BigQuery Dataset & Tables

- Tạo dataset `stock` (hoặc tên khác nhưng phải đồng bộ với:
  - `dbt_profiles/profiles.yml` (fields `project`, `dataset`).
  - Các constant trong `infra/dags/minio_to_bigquery_multi.py`:
    - `BQ_PROJECT`, `BQ_DATASET`, `BQ_TABLE`, `BQ_META_TABLE`.
- Nếu cần, tạo trước bảng:
  - `bronze_stock_quotes_raw`
  - `metadata_last_ts` với schema đơn giản (`symbol` STRING, `last_ts` INT64).
- Các bảng còn lại sẽ được dbt tạo khi chạy `dbt run`.

### 3. Khởi động Docker Compose (hạ tầng)

Từ thư mục `infra/`:

```bash
docker-compose up -d --build
```

Các service chính:

- Kafka: `localhost:29092` (PLAINTEXT_HOST)
- Kafdrop UI: `http://localhost:9000`
- MinIO:
  - Console: `http://localhost:9001`
  - S3 endpoint: `http://localhost:9002`
  - Tài khoản mặc định: user `admin`, password `password123`
- Airflow Webserver: `http://localhost:8080`
  - username: `admin`
  - password: `admin`
- Grafana: `http://localhost:3000`
  - Mặc định: user `admin` / pass `admin` (hoặc tuỳ config image).

Lệnh kiểm tra container:

```bash
docker-compose ps
```

### 4. Chạy Airflow DAG

- Truy cập Airflow UI `http://localhost:8080`.
- Đảm bảo DAG `minio_to_bigquery_multi` đã được load:
  - Nếu chưa, kiểm tra mount `./dags` trong `docker-compose.yml`.
- Bật (`On`) DAG `minio_to_bigquery_multi`.
- DAG sẽ:
  - Mỗi phút:
    - Với từng symbol:
      - Tìm file mới trong MinIO (so với `metadata_last_ts`).
      - Download về local `/tmp/minio_downloads`.
      - Load JSON vào BigQuery bảng `bronze_stock_quotes_raw`.
      - Xóa file local sau khi load.
    - Nếu tổng số file mới > 0 thì gọi:
      - `dbt deps`
      - `dbt run --target prod`

---

## Chạy Producer & Consumer

Bạn có thể chạy **ngoài Docker** (dùng Python local) hoặc đóng gói vào container riêng, tùy ý. Hiện tại code giả định:

- Kafka broker host: `localhost:29092` (PLAINTEXT_HOST từ `docker-compose.yml`).
- MinIO endpoint: `http://localhost:9002`.

### 1. Cài môi trường Python local (tùy chọn)

```bash
python -m venv venv312
venv312\Scripts\activate  # trên Windows
pip install -r requirements.txt
```

### 2. Thiết lập Finnhub API Key

Trong `infra/producer/producer.py`:

- Field:
  - `API_KEY = "..."` → thay bằng key thật của bạn.

Bạn cũng có thể chuyển thành biến môi trường nếu muốn bảo mật hơn.

### 3. Chạy Producer

Từ thư mục `infra/`:

```bash
venv312\Scripts\activate
python producer/producer.py
```

Producer sẽ:

- Mỗi vài giây:
  - Gọi Finnhub API cho từng mã trong `SYMBOLS`.
  - Emit JSON record vào Kafka topic `stock-quotes`.

### 4. Chạy Consumer

Trong một terminal khác:

```bash
venv312\Scripts\activate
python consumer/consumer.py
```

Consumer sẽ:

- Đảm bảo bucket `bronze-transactions` tồn tại trên MinIO.
- Đọc từng message từ topic `stock-quotes`.
- Ghi file JSON theo dạng `symbol/fetched_at.json` vào MinIO.

---

## dbt Project (`dbt_stocks`)

### Cấu hình

- File `dbt_stocks/dbt_project.yml`:
  - Đặt `schema` cho từng layer:
    - `bronze`: `+schema: bronze`, `+materialized: table`
    - `silver`: `+schema: silver`
    - `gold`: `+schema: gold`
- File `dbt_profiles/profiles.yml`:
  - Profile `dbt_stocks`:
    - `type: bigquery`
    - `method: service-account`
    - `project: real-time-stock-analytics-25` (chỉnh lại theo project của bạn).
    - `dataset: stock`
    - `keyfile: /opt/airflow/keys/airflow_gcp_key.json`.

### Chạy dbt thủ công (tùy chọn)

Nếu muốn test dbt từ local:

```bash
cd dbt_stocks
dbt deps
dbt run --profiles-dir ../dbt_profiles --target prod
```

Đảm bảo:

- Đã cài `dbt-core` + adapter BigQuery (`dbt-bigquery`).
- Biến môi trường / đường dẫn `keyfile` trong `profiles.yml` trỏ đúng file key JSON.

---

## Kết nối Grafana với BigQuery

Tuỳ plugin bạn dùng:

- Cách phổ biến:
  - Cài plugin BigQuery cho Grafana (ví dụ `grafana-bigquery-datasource`).
  - Import service account key vào Grafana hoặc sử dụng GCP JSON key / OAuth.
  - Tạo Data Source kiểu BigQuery, trỏ tới project `real-time-stock-analytics-25` và dataset `stock`.
  - Viết query lên các bảng `gold_*` trong BigQuery:
    - `gold_kpi_latest`
    - `gold_ohlc_daily`
    - `gold_sma_daily`
    - `gold_rsi_daily`
    - ...
- Nếu thư mục `grafana_dashboards/` có JSON:
  - Vào Grafana → Dashboards → Import → chọn file JSON → gán vào data source BigQuery.

---

## Troubleshooting & Ghi chú

- **Kafka không connect được**:
  - Kiểm tra `bootstrap_servers` trong `producer.py` & `consumer.py` có khớp với `KAFKA_ADVERTISED_LISTENERS` trong `docker-compose.yml` (`localhost:29092`).
- **MinIO không truy cập được**:
  - Đảm bảo container `minio` chạy, endpoint là `http://localhost:9002`.
  - Dùng `mc` hoặc MinIO console để kiểm tra bucket `bronze-transactions`.
- **Airflow không đọc DAG**:
  - Kiểm tra mount `./dags:/opt/airflow/dags` trong `docker-compose.yml`.
  - Xem log scheduler container.
- **dbt lỗi credential**:
  - Kiểm tra đường dẫn `keyfile` trong `profiles.yml` có tồn tại trong container Airflow.
  - Kiểm tra biến `GOOGLE_APPLICATION_CREDENTIALS`.
- **BigQuery quota / pricing**:
  - Pipeline có thể query khá thường xuyên; cần giám sát quota & chi phí trên GCP.

---

## Hướng phát triển thêm

- Thêm nhiều nguồn dữ liệu khác (order book, news sentiment, crypto, forex...).
- Tối ưu schema, partition / clustering trên BigQuery để giảm chi phí & tăng tốc độ truy vấn.
- Thêm alerting trong Grafana (giá vượt ngưỡng, RSI quá mua/quá bán...).
- Đóng gói producer/consumer & DAG vào CI/CD pipeline để deploy lên môi trường cloud (GKE, Cloud Run, ECS, v.v.).


