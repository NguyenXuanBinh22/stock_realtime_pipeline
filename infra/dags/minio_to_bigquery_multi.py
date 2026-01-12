import os
import json
import boto3
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator, ShortCircuitOperator
from airflow.operators.bash import BashOperator
from google.cloud import bigquery

# ----------------------------------------
# CONFIG
# ----------------------------------------
MINIO_ENDPOINT = "http://minio:9000"
MINIO_ACCESS_KEY = "admin"
MINIO_SECRET_KEY = "password123"
BUCKET = "bronze-transactions"
LOCAL_DIR = "/tmp/minio_downloads"

BQ_PROJECT = "real-time-stock-analytics-25"
BQ_DATASET = "stock"
BQ_TABLE = "bronze_stock_quotes_raw"
BQ_META_TABLE = "metadata_last_ts"

SYMBOLS = ["AAPL", "MSFT", "TSLA", "GOOGL", "AMZN"]

# DBT CONFIG (bạn chỉnh lại cho khớp container)
DBT_PROJECT_DIR = "/opt/airflow/dbt_stocks"
DBT_TARGET = "prod"
DBT_PROFILES_DIR = "/opt/airflow/dbt_profiles"


# ----------------------------------------
# BigQuery helpers (read + write last_ts)
# ----------------------------------------
def get_last_ts(symbol):
    client = bigquery.Client()
    query = f"""
        SELECT last_ts
        FROM `{BQ_PROJECT}.{BQ_DATASET}.{BQ_META_TABLE}`
        WHERE symbol = '{symbol}'
        LIMIT 1
    """
    rows = list(client.query(query))
    return rows[0].last_ts if rows else 0


def update_last_ts(symbol, last_ts):
    client = bigquery.Client()
    query = f"""
        MERGE `{BQ_PROJECT}.{BQ_DATASET}.{BQ_META_TABLE}` T
        USING (SELECT '{symbol}' AS symbol, {last_ts} AS last_ts) S
        ON T.symbol = S.symbol
        WHEN MATCHED THEN UPDATE SET last_ts = S.last_ts
        WHEN NOT MATCHED THEN INSERT (symbol, last_ts) VALUES (S.symbol, S.last_ts)
    """
    client.query(query).result()


# ----------------------------------------
# S3/MINIO PAGINATION (fix 1000-object limit)
# ----------------------------------------
def list_all_objects(s3, bucket, prefix):
    objects = []
    token = None

    while True:
        if token:
            resp = s3.list_objects_v2(
                Bucket=bucket,
                Prefix=prefix,
                ContinuationToken=token
            )
        else:
            resp = s3.list_objects_v2(
                Bucket=bucket,
                Prefix=prefix
            )

        contents = resp.get("Contents", [])
        objects.extend(contents)

        if resp.get("IsTruncated"):
            token = resp["NextContinuationToken"]
        else:
            break

    return objects


# ----------------------------------------
# 1. Download only NEW files from MinIO
# ----------------------------------------
def download_from_minio(symbol, **context):
    os.makedirs(LOCAL_DIR, exist_ok=True)

    last_ts = get_last_ts(symbol)
    print(f"[{symbol}] Last loaded timestamp = {last_ts}")

    s3 = boto3.client(
        "s3",
        endpoint_url=MINIO_ENDPOINT,
        aws_access_key_id=MINIO_ACCESS_KEY,
        aws_secret_access_key=MINIO_SECRET_KEY,
    )

    prefix = f"{symbol}/"
    objects = list_all_objects(s3, BUCKET, prefix)

    # Sort filenames by timestamp to avoid out-of-order issues
    def _safe_ts(obj_key: str) -> int:
        try:
            return int(os.path.basename(obj_key).replace(".json", ""))
        except Exception:
            return -1

    objects.sort(key=lambda o: _safe_ts(o["Key"]))

    new_files = []
    max_ts = last_ts

    for obj in objects:
        key = obj["Key"]
        fname = os.path.basename(key).replace(".json", "")

        try:
            ts = int(fname)
        except Exception:
            continue

        # Pick only new files
        if ts > last_ts:
            local_path = os.path.join(LOCAL_DIR, f"{symbol}_{fname}.json")
            s3.download_file(BUCKET, key, local_path)
            new_files.append(local_path)
            max_ts = max(max_ts, ts)

    context["ti"].xcom_push(key=f"{symbol}_files", value=new_files)
    context["ti"].xcom_push(key=f"{symbol}_max_ts", value=max_ts)

    print(f"[{symbol}] New files count: {len(new_files)}")
    return new_files


# ----------------------------------------
# 2. Load new JSON files into BigQuery
# ----------------------------------------
def load_bigquery(symbol, **context):
    client = bigquery.Client()
    table_id = f"{BQ_PROJECT}.{BQ_DATASET}.{BQ_TABLE}"

    files = context["ti"].xcom_pull(key=f"{symbol}_files")
    if not files:
        print(f"[{symbol}] No new files to load.")
        return 0  # return count for easier gating (optional)

    rows = []
    for path in files:
        try:
            with open(path, "r") as f:
                rows.append(json.load(f))
        except Exception:
            continue
        finally:
            # Always try cleanup local file to avoid disk growth
            try:
                os.remove(path)
            except Exception:
                pass

    if not rows:
        print(f"[{symbol}] No valid rows.")
        return 0

    errors = client.insert_rows_json(table_id, rows)
    if errors:
        print(f"[{symbol}] BigQuery errors: {errors}")
        # Nếu muốn fail task khi insert lỗi:
        # raise RuntimeError(errors)
    else:
        print(f"[{symbol}] Loaded {len(rows)} rows!")

    max_ts = context["ti"].xcom_pull(key=f"{symbol}_max_ts")
    update_last_ts(symbol, max_ts)
    print(f"[{symbol}] Updated last_ts to {max_ts}")

    return len(rows)


# ----------------------------------------
# 3. Gate: run dbt only if there is any new file across symbols
# ----------------------------------------
def should_run_dbt(**context) -> bool:
    ti = context["ti"]
    total_new_files = 0

    for symbol in SYMBOLS:
        files = ti.xcom_pull(key=f"{symbol}_files") or []
        total_new_files += len(files)

    print(f"[gate] Total new files across symbols: {total_new_files}")

    # True => downstream runs, False => downstream skipped
    return total_new_files > 0


# ----------------------------------------
# DAG CONFIG
# ----------------------------------------
default_args = {
    "owner": "airflow",
    "start_date": datetime(2025, 1, 1),
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
}

with DAG(
    dag_id="minio_to_bigquery_multi",
    default_args=default_args,
    schedule_interval="* * * * *",   # every 1 minute
    catchup=False,
    max_active_runs=1,               # rất quan trọng khi có dbt run
) as dag:

    load_tasks = []

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

        t1 >> t2
        load_tasks.append(t2)

    gate_dbt = ShortCircuitOperator(
        task_id="gate_dbt_run_if_new_data",
        python_callable=should_run_dbt,
    )

    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command="""
        set -e
        cd /opt/airflow/dbt_stocks
        /home/airflow/.local/bin/dbt deps
        /home/airflow/.local/bin/dbt run --target prod
        """,
        env={
            "DBT_PROFILES_DIR": "/opt/airflow/dbt_profiles",
        },
    )


    # Chỉ chạy dbt sau khi tất cả load xong, và chỉ khi có data mới
    load_tasks >> gate_dbt >> dbt_run
