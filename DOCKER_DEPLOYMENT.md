# Docker Deployment - Hướng Dẫn Ngắn Gọn

## 🚀 Quick Start

### 1. Build Custom Airflow Image

```bash
cd infra
docker build -t airflow-custom:latest .
```

**Dockerfile làm gì:**
- Base image: `apache/airflow:2.9.3`
- Install packages từ `requirements.txt` (boto3, google-cloud-bigquery, ...)
- Tạo image `airflow-custom:latest` để dùng cho webserver và scheduler

### 2. Start Tất Cả Services

```bash
docker-compose up -d
```

**Services được start:**
- **Zookeeper** → **Kafka** → **Kafdrop** (Kafka ecosystem)
- **MinIO** (Object storage)
- **PostgreSQL** (Airflow metadata)
- **Airflow Init** (One-time: init DB + create admin user)
- **Airflow Webserver** (UI: http://localhost:8080)
- **Airflow Scheduler** (Chạy DAGs)
- **Grafana** (Monitoring: http://localhost:3000)

### 3. Kiểm Tra Services

```bash
# Xem status
docker-compose ps

# Xem logs
docker-compose logs -f airflow-scheduler
docker-compose logs -f kafka
```

## 📋 Services Overview

| Service | Port | Purpose | Access |
|---------|------|---------|--------|
| **Kafka** | 29092 | Message broker | `localhost:29092` |
| **Kafdrop** | 9000 | Kafka UI | http://localhost:9000 |
| **MinIO Console** | 9001 | MinIO UI | http://localhost:9001 |
| **MinIO API** | 9002 | S3 API | `localhost:9002` |
| **PostgreSQL** | 5432 | Airflow DB | `localhost:5432` |
| **Airflow** | 8080 | Airflow UI | http://localhost:8080 |
| **Grafana** | 3000 | Dashboards | http://localhost:3000 |

## 🔑 Key Points

### **Dependencies (Start Order)**
```
postgres → airflow-init → airflow-webserver → airflow-scheduler
zookeeper → kafka → kafdrop
```

### **Volumes (Persistent Data)**
- `postgres_data`: Airflow metadata
- `minio_data`: Object storage files
- `grafana_data`: Grafana dashboards

### **Volume Mounts (Hot Reload)**
- `./dags` → `/opt/airflow/dags` (DAG files)
- `./airflow_gcp_key.json` → `/opt/airflow/airflow_gcp_key.json` (GCP credentials)
- `./logs` → `/opt/airflow/logs` (Task logs)

### **Environment Variables**
- `GOOGLE_APPLICATION_CREDENTIALS`: Path to GCP service account key
- `GCP_PROJECT`: BigQuery project ID
- `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN`: PostgreSQL connection string

## 🛠️ Common Commands

```bash
# Start services
docker-compose up -d

# Stop services
docker-compose down

# Stop và xóa volumes (⚠️ mất data)
docker-compose down -v

# Rebuild Airflow image
docker-compose build airflow-webserver airflow-scheduler

# Restart một service
docker-compose restart airflow-scheduler

# Xem logs real-time
docker-compose logs -f [service-name]

# Execute command trong container
docker-compose exec airflow-webserver bash
```

## ⚠️ Lưu Ý

1. **Airflow Init**: Chạy 1 lần duy nhất khi start lần đầu
2. **GCP Credentials**: File `airflow_gcp_key.json` phải tồn tại trong `infra/`
3. **Port Conflicts**: Đảm bảo các ports (8080, 9000, 29092, ...) không bị conflict
4. **Memory**: Kafka và Airflow cần đủ RAM (recommend 4GB+)

## 🔄 Workflow Sau Khi Deploy

1. **Start Producer** (external):
   ```bash
   python infra/producer/producer.py
   ```

2. **Start Consumer** (external):
   ```bash
   python infra/consumer/consumer.py
   ```

3. **Airflow DAG**: Tự động chạy mỗi 1 phút (schedule: `* * * * *`)

4. **dbt Transform** (manual hoặc schedule):
   ```bash
   cd dbt_stocks
   dbt run
   ```

## 🐛 Troubleshooting

**Airflow không start:**
```bash
# Check logs
docker-compose logs airflow-webserver

# Rebuild image
docker-compose build airflow-webserver
docker-compose up -d airflow-webserver
```

**Kafka connection error:**
```bash
# Check Kafka status
docker-compose logs kafka

# Restart Kafka
docker-compose restart kafka
```

**BigQuery authentication error:**
- Kiểm tra file `airflow_gcp_key.json` có tồn tại
- Kiểm tra environment variable `GOOGLE_APPLICATION_CREDENTIALS`

