# Phân Tích Chi Tiết: Producer → Consumer & Kafka Topic

## 📋 Tổng Quan

Phần này phân tích chi tiết luồng dữ liệu từ **Producer** (thu thập từ Finnhub API) qua **Kafka Topic** đến **Consumer** (lưu vào MinIO), bao gồm cấu hình, cơ chế hoạt động, và các đặc điểm kỹ thuật.

---

## 🔄 Luồng Dữ Liệu Tổng Thể

```
┌─────────────────────────────────────────────────────────────────┐
│                    PRODUCER → KAFKA → CONSUMER                   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────┐         ┌──────────────┐         ┌─────────────┐
│  Finnhub    │  HTTP   │   Producer   │  Kafka  │   Kafka     │
│    API      │────────▶│  producer.py │────────▶│   Topic:    │
│             │ Request │              │ Message │ stock-quotes│
└─────────────┘         └──────────────┘         └──────┬──────┘
                                                         │
                                                         │ Consume
                                                         ▼
                                                ┌──────────────┐
                                                │   Consumer   │
                                                │ consumer.py  │
                                                └──────┬───────┘
                                                       │
                                                       │ S3 API
                                                       ▼
                                                ┌──────────────┐
                                                │    MinIO     │
                                                │ bronze-trans-│
                                                │  actions/    │
                                                └──────────────┘
```

---

## 1. 🚀 PRODUCER (producer.py)

### 1.1 Cấu Hình Kafka Producer

**File**: `infra/producer/producer.py`

```python
producer = KafkaProducer(
    bootstrap_servers=["localhost:29092"],
    value_serializer=lambda v: json.dumps(v).encode("utf-8")
)
```

**Phân tích cấu hình:**

| Tham số | Giá trị | Mô tả |
|---------|---------|-------|
| `bootstrap_servers` | `["localhost:29092"]` | Kafka broker endpoint (external port) |
| `value_serializer` | `lambda v: json.dumps(v).encode("utf-8")` | Serialize Python dict → JSON string → UTF-8 bytes |

**Chi tiết:**
- **Bootstrap Server**: `localhost:29092` là external port được expose từ Docker container
- **Serialization Pipeline**: 
  ```
  Python dict → JSON string → UTF-8 bytes → Kafka binary format
  ```
- **Default Settings** (không khai báo):
  - `acks=1`: Producer chờ acknowledgment từ leader partition
  - `retries=2147483647`: Retry vô hạn (default)
  - `batch_size=16384`: Batch 16KB trước khi gửi
  - `linger_ms=0`: Gửi ngay lập tức (không đợi batch)

### 1.2 Quy Trình Thu Thập Dữ Liệu

```python
# 1. Fetch từ API
def fetch_quote(symbol):
    url = f"{BASE_URL}?symbol={symbol}&token={API_KEY}"
    response = requests.get(url)
    data = response.json()
    data["symbol"] = symbol              # Enrichment
    data["fetched_at"] = int(time.time()) # Enrichment
    return data

# 2. Loop và publish
while True:
    for symbol in SYMBOLS:  # ["AAPL","MSFT","TSLA","GOOGL","AMZN"]
        quote = fetch_quote(symbol)
        if quote:
            producer.send("stock-quotes", value=quote)
    time.sleep(6)  # Rate limiting
```

**Phân tích:**

1. **Data Enrichment**:
   - Thêm `symbol`: Để consumer biết message thuộc symbol nào
   - Thêm `fetched_at`: Timestamp khi fetch (epoch seconds) - dùng làm key trong MinIO

2. **Rate Limiting**:
   - **5 symbols** × **10 calls/phút** = **50 calls/phút**
   - Finnhub limit: **60 calls/phút**
   - Sleep **6 giây** giữa các batch → **10 batches/phút** = **50 messages/phút**

3. **Error Handling**:
   - Try-catch trong `fetch_quote()` → return `None` nếu fail
   - Check `if quote:` trước khi send → skip nếu fetch fail
   - **Không block**: Nếu 1 symbol fail, vẫn tiếp tục với symbols khác

### 1.3 Message Format

**Input từ Finnhub API:**
```json
{
  "c": 150.25,    // current price
  "d": 2.50,      // change amount
  "dp": 1.69,     // change percent
  "h": 152.00,    // day high
  "l": 148.50,    // day low
  "o": 149.00,    // day open
  "pc": 147.75,   // previous close
  "t": 1704067200 // market timestamp (epoch)
}
```

**Sau khi Producer enrich:**
```json
{
  "c": 150.25,
  "d": 2.50,
  "dp": 1.69,
  "h": 152.00,
  "l": 148.50,
  "o": 149.00,
  "pc": 147.75,
  "t": 1704067200,
  "symbol": "AAPL",           // ← Added by producer
  "fetched_at": 1704067256    // ← Added by producer
}
```

**Kafka Message Structure:**
- **Topic**: `stock-quotes`
- **Key**: `None` (không partition key → round-robin)
- **Value**: JSON bytes (UTF-8 encoded)
- **Headers**: None
- **Timestamp**: Auto-generated by Kafka

### 1.4 Producer Behavior

**Asynchronous Send:**
- `producer.send()` là **non-blocking**
- Message được đưa vào **buffer** và gửi bất đồng bộ
- **Không đợi** acknowledgment trước khi tiếp tục

**Partitioning Strategy:**
- Không có key → **Round-robin** distribution
- 5 symbols → messages được phân bố đều across partitions
- **Không đảm bảo** messages của cùng symbol vào cùng partition

**Throughput:**
- **50 messages/phút** = **~0.83 messages/giây**
- **~3000 messages/giờ**
- **~72,000 messages/ngày**

---

## 2. 📨 KAFKA TOPIC: `stock-quotes`

### 2.1 Cấu Hình Kafka Broker

**File**: `infra/docker-compose.yml`

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

**Phân tích Listeners:**

| Listener | Port | Mục đích | Sử dụng bởi |
|----------|------|----------|-------------|
| `PLAINTEXT://0.0.0.0:9092` | 9092 | Internal (container-to-container) | Airflow, services trong Docker network |
| `PLAINTEXT_HOST://0.0.0.0:29092` | 29092 | External (host-to-container) | Producer, Consumer chạy trên host |

**Advertised Listeners:**
- Kafka trả về địa chỉ này cho clients khi connect
- Internal: `kafka:9092` (DNS trong Docker network)
- External: `localhost:29092` (host machine)

### 2.2 Topic Configuration

**Topic Name**: `stock-quotes`

**Default Settings** (nếu không tạo explicit):
- **Partitions**: `1` (default)
- **Replication Factor**: `1` (single broker)
- **Retention**: `7 days` (default)
- **Segment Size**: `1GB` (default)
- **Cleanup Policy**: `delete` (default)

**Tạo Topic (nếu cần):**
```bash
kafka-topics --create \
  --bootstrap-server localhost:29092 \
  --topic stock-quotes \
  --partitions 3 \
  --replication-factor 1
```

**Lưu ý:**
- **Single Broker**: Không có replication → **không fault-tolerant**
- **Single Partition**: Không thể scale consumer → **bottleneck**
- **Production nên**: ≥3 partitions, ≥3 brokers, replication factor ≥2

### 2.3 Message Storage

**Kafka Log Structure:**
```
stock-quotes-0/
├── 00000000000000000000.log  (messages)
├── 00000000000000000000.index
└── 00000000000000000000.timeindex
```

**Message Format trong Log:**
- **Offset**: Sequential number (0, 1, 2, ...)
- **Timestamp**: Auto-generated
- **Key**: `null` (không có key)
- **Value**: Binary (JSON bytes)
- **Headers**: Empty

**Retention:**
- Messages được giữ **7 ngày** (default)
- Sau 7 ngày → auto-delete
- Consumer có thể đọc lại từ `earliest` offset nếu cần

### 2.4 Offset Management

**Consumer Group**: `bronze-Consumer`
- Kafka lưu **offset** cho mỗi consumer group
- Offset được commit vào `__consumer_offsets` topic
- **Replication Factor**: 1 (single broker)

**Offset Storage:**
```
__consumer_offsets/
├── Partition 0: {group_id: "bronze-Consumer", topic: "stock-quotes", offset: 12345}
└── ...
```

---

## 3. 📥 CONSUMER (consumer.py)

### 3.1 Cấu Hình Kafka Consumer

**File**: `infra/consumer/consumer.py`

```python
consumer = KafkaConsumer(
    "stock-quotes",
    bootstrap_servers=["localhost:29092"],
    enable_auto_commit=True,
    auto_offset_reset="earliest",
    group_id="bronze-Consumer",
    value_deserializer=lambda v: json.loads(v.decode("utf-8"))
)
```

**Phân tích cấu hình:**

| Tham số | Giá trị | Mô tả |
|---------|---------|-------|
| `bootstrap_servers` | `["localhost:29092"]` | Kafka broker endpoint |
| `group_id` | `"bronze-Consumer"` | Consumer group ID (đảm bảo không mất message) |
| `enable_auto_commit` | `True` | Tự động commit offset sau khi consume |
| `auto_offset_reset` | `"earliest"` | Nếu không có offset → đọc từ đầu |
| `value_deserializer` | `lambda v: json.loads(v.decode("utf-8"))` | Deserialize: bytes → UTF-8 string → JSON → Python dict |

**Chi tiết:**

1. **Consumer Group**:
   - **Group ID**: `bronze-Consumer`
   - **Partition Assignment**: Nếu 1 consumer → nhận tất cả partitions
   - **Load Balancing**: Nếu nhiều consumers cùng group → chia partitions

2. **Offset Management**:
   - **Auto Commit**: `True` → commit sau mỗi `auto.commit.interval.ms` (default: 5s)
   - **Offset Reset**: `earliest` → nếu không có offset → đọc từ đầu topic
   - **At-least-once**: Có thể đọc lại message nếu crash trước khi commit

3. **Deserialization Pipeline**:
   ```
   Kafka binary → UTF-8 bytes → JSON string → Python dict
   ```

### 3.2 Quy Trình Consume & Lưu Trữ

```python
# 1. Khởi tạo MinIO client
s3 = boto3.client(
    "s3",
    endpoint_url="http://localhost:9002",
    aws_access_key_id="admin",
    aws_secret_access_key="password123"
)

# 2. Consume loop
for message in consumer:
    record = message.value  # Python dict (đã deserialize)
    symbol = record.get("symbol")
    ts = record.get("fetched_at", int(time.time()))
    key = f"{symbol}/{ts}.json"
    
    # 3. Lưu vào MinIO
    s3.put_object(
        Bucket="bronze-transactions",
        Key=key,
        Body=json.dumps(record),
        ContentType="application/json"
    )
```

**Phân tích:**

1. **Message Processing**:
   - **Blocking Loop**: `for message in consumer` → đợi message mới
   - **Synchronous**: Xử lý từng message một (không parallel)
   - **Error Handling**: Không có try-catch → crash nếu có lỗi

2. **MinIO Key Structure**:
   - **Format**: `{symbol}/{timestamp}.json`
   - **Ví dụ**: `AAPL/1704067256.json`
   - **Lợi ích**: 
     - Dễ query theo symbol
     - Timestamp unique → không duplicate
     - Dễ sort theo thời gian

3. **Data Flow**:
   ```
   Kafka Message (bytes)
       ↓ deserialize
   Python dict
       ↓ extract symbol, fetched_at
   MinIO Key: {symbol}/{ts}.json
       ↓ json.dumps
   JSON string
       ↓ S3 API
   MinIO Object Storage
   ```

### 3.3 Consumer Behavior

**Processing Model:**
- **Sequential**: Xử lý từng message một
- **Blocking**: Đợi MinIO upload xong mới tiếp tục
- **No Batching**: Mỗi message → 1 file riêng

**Throughput:**
- **Latency**: ~100-500ms/message (tùy MinIO)
- **Throughput**: ~2-10 messages/giây (nếu không bottleneck)
- **Current Load**: 50 messages/phút = ~0.83 messages/giây → **không bottleneck**

**Reliability:**
- **At-least-once**: Có thể đọc lại message nếu crash
- **No Idempotency**: Nếu đọc lại → tạo file duplicate (cùng key)
- **Risk**: Nếu MinIO fail → message bị mất (đã commit offset)

---

## 4. 🔍 Phân Tích Chi Tiết Luồng Dữ Liệu

### 4.1 End-to-End Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    STEP-BY-STEP DATA FLOW                        │
└─────────────────────────────────────────────────────────────────┘

1. PRODUCER FETCH
   ┌─────────────┐
   │  Finnhub    │ HTTP GET /api/v1/quote?symbol=AAPL&token=xxx
   │    API      │──────────────────────────────────────────────┐
   └─────────────┘                                              │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ Response: {"c": 150.25, "d": 2.50, ..., "t": 1704067200}   │
   └─────────────────────────────────────────────────────────────┘
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ Enrichment: + "symbol": "AAPL"                             │
   │            + "fetched_at": 1704067256                       │
   └─────────────────────────────────────────────────────────────┘

2. KAFKA PRODUCE
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ producer.send("stock-quotes", value=quote)                  │
   │   → Serialize: dict → JSON → UTF-8 bytes                   │
   │   → Send to Kafka broker (localhost:29092)                  │
   └─────────────────────────────────────────────────────────────┘
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ Kafka Topic: stock-quotes                                   │
   │   - Partition: 0 (round-robin)                              │
   │   - Offset: 12345                                           │
   │   - Value: Binary (JSON bytes)                              │
   │   - Timestamp: 1704067256000                                │
   └─────────────────────────────────────────────────────────────┘

3. KAFKA CONSUME
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ consumer.poll() → Fetch message from Kafka                  │
   │   - Topic: stock-quotes                                     │
   │   - Partition: 0                                            │
   │   - Offset: 12345                                           │
   │   - Value: Binary (JSON bytes)                              │
   └─────────────────────────────────────────────────────────────┘
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ Deserialize: bytes → UTF-8 string → JSON → Python dict     │
   │   → record = {"c": 150.25, "symbol": "AAPL", ...}          │
   └─────────────────────────────────────────────────────────────┘

4. MINIO STORAGE
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ Extract: symbol = "AAPL", ts = 1704067256                  │
   │ Key: "AAPL/1704067256.json"                                 │
   └─────────────────────────────────────────────────────────────┘
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ s3.put_object(                                              │
   │   Bucket="bronze-transactions",                             │
   │   Key="AAPL/1704067256.json",                               │
   │   Body=json.dumps(record)                                   │
   │ )                                                           │
   └─────────────────────────────────────────────────────────────┘
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ MinIO: bronze-transactions/AAPL/1704067256.json            │
   │   → File stored successfully                                │
   └─────────────────────────────────────────────────────────────┘

5. OFFSET COMMIT
                                                                │
                                                                ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ Auto-commit offset: 12345                                   │
   │   → Saved to __consumer_offsets topic                      │
   │   → Consumer group: bronze-Consumer                        │
   └─────────────────────────────────────────────────────────────┘
```

### 4.2 Timing & Latency

**Latency Breakdown:**

| Step | Latency | Mô tả |
|------|---------|-------|
| API Request | 100-500ms | HTTP GET từ Finnhub |
| Producer Send | <10ms | Serialize + buffer |
| Kafka Storage | <10ms | Write to log |
| Consumer Poll | <10ms | Fetch from Kafka |
| Deserialize | <1ms | Bytes → dict |
| MinIO Upload | 50-200ms | S3 API call |
| Offset Commit | <10ms | Write to __consumer_offsets |
| **Total** | **~200-750ms** | End-to-end latency |

**Throughput:**
- **Producer**: 50 messages/phút = **0.83 msg/s**
- **Consumer**: Có thể xử lý **2-10 msg/s** → **không bottleneck**
- **Buffer**: Kafka buffer messages → consumer có thể catch up

### 4.3 Error Scenarios

**1. Producer Fail:**
```
Finnhub API Error → fetch_quote() return None → Skip message
→ Không ảnh hưởng đến messages khác
→ Continue với symbols tiếp theo
```

**2. Kafka Broker Down:**
```
producer.send() → ConnectionError
→ Producer retry (default: infinite)
→ Messages buffer trong memory
→ Risk: Memory overflow nếu down lâu
```

**3. Consumer Crash:**
```
Consumer crash → Offset chưa commit
→ Auto-commit interval: 5s
→ Risk: Re-read last 5s messages (at-least-once)
→ MinIO: Duplicate files (cùng key → overwrite)
```

**4. MinIO Fail:**
```
s3.put_object() → Error
→ Consumer crash (no error handling)
→ Offset đã commit → Message lost
→ Risk: Data loss
```

---

## 5. 🎯 Điểm Mạnh & Hạn Chế

### 5.1 Điểm Mạnh

1. **Decoupling**:
   - Producer và Consumer độc lập
   - Kafka làm buffer → không block nhau

2. **Scalability**:
   - Có thể scale producer/consumer độc lập
   - Kafka handle high throughput

3. **Reliability**:
   - Consumer group đảm bảo không mất message
   - Offset tracking → có thể resume

4. **Real-time**:
   - Low latency (~200-750ms)
   - Near real-time processing

### 5.2 Hạn Chế & Rủi Ro

1. **Single Partition**:
   - Không thể scale consumer
   - Bottleneck nếu throughput tăng

2. **No Replication**:
   - Single broker → không fault-tolerant
   - Nếu Kafka down → mất tất cả messages

3. **Error Handling**:
   - Consumer không có try-catch → crash nếu MinIO fail
   - Risk: Data loss nếu offset đã commit

4. **No Idempotency**:
   - Duplicate messages → duplicate files
   - Cùng key → overwrite (may mắn)

5. **No Batching**:
   - Mỗi message → 1 file
   - Inefficient cho MinIO (nhiều small files)

---

## 6. 🔧 Khuyến Nghị Cải Thiện

### 6.1 Immediate Improvements

1. **Error Handling trong Consumer**:
```python
for message in consumer:
    try:
        # Process message
        s3.put_object(...)
    except Exception as e:
        print(f"Error processing message: {e}")
        # Log to dead letter queue
        continue  # Skip và tiếp tục
```

2. **Manual Offset Commit**:
```python
enable_auto_commit=False
# Commit sau khi upload thành công
consumer.commit()
```

3. **Partition Key**:
```python
# Producer: Dùng symbol làm key
producer.send("stock-quotes", key=symbol.encode(), value=quote)
# → Messages cùng symbol vào cùng partition
```

### 6.2 Production-Ready Improvements

1. **Multiple Partitions**:
   - Tạo topic với 3-5 partitions
   - Scale consumer instances

2. **Replication**:
   - ≥3 Kafka brokers
   - Replication factor ≥2

3. **Idempotency**:
   - Check file exists trước khi upload
   - Hoặc dùng unique key (symbol + timestamp + offset)

4. **Batching**:
   - Batch messages theo symbol hoặc time window
   - Upload nhiều records vào 1 file

5. **Monitoring**:
   - Lag monitoring (consumer lag)
   - Error rate tracking
   - Throughput metrics

---

## 7. 📊 Metrics & Monitoring

### 7.1 Key Metrics

**Producer Metrics:**
- Messages sent per second
- Error rate
- Latency (API → Kafka)

**Kafka Metrics:**
- Messages in topic
- Consumer lag
- Partition size
- Retention usage

**Consumer Metrics:**
- Messages consumed per second
- Processing latency
- MinIO upload success rate
- Error rate

### 7.2 Monitoring Tools

1. **Kafdrop** (http://localhost:9000):
   - View topics, messages, consumer groups
   - Monitor consumer lag
   - Inspect message content

2. **Kafka CLI**:
```bash
# Check consumer lag
kafka-consumer-groups --bootstrap-server localhost:29092 \
  --group bronze-Consumer --describe

# View topic details
kafka-topics --bootstrap-server localhost:29092 \
  --topic stock-quotes --describe
```

---

## 📝 Tóm Tắt

**Producer → Consumer Flow:**
1. Producer fetch từ Finnhub API (5 symbols, mỗi 6s)
2. Enrich data (thêm symbol, fetched_at)
3. Serialize và gửi vào Kafka topic `stock-quotes`
4. Consumer poll messages từ Kafka
5. Deserialize và lưu vào MinIO (key: `{symbol}/{timestamp}.json`)
6. Auto-commit offset

**Đặc điểm:**
- **Throughput**: 50 messages/phút
- **Latency**: ~200-750ms end-to-end
- **Reliability**: At-least-once delivery
- **Scalability**: Có thể scale nhưng hiện tại single partition

**Rủi ro:**
- Single partition → không scale consumer
- No replication → không fault-tolerant
- No error handling → risk data loss
- No idempotency → duplicate files

