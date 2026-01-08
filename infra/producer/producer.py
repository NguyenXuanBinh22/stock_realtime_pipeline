#Import requirements
import time
import json
import requests
from kafka import KafkaProducer

#Define variable API
API_KEY = "d4139g9r01qr2l0cd2v0d4139g9r01qr2l0cd2vg"
BASE_URL = "https://finnhub.io/api/v1/quote"
SYMBOLS = ["AAPL","MSFT","TSLA","GOOGL","AMZN"]

#Initialize Producer
producer = KafkaProducer(
    bootstrap_servers=["localhost:29092"], #host.docker.internal
    value_serializer = lambda v: json.dumps(v).encode("utf-8") # python dict -> json -> byte??
)

#retrieve data
def fetch_quote(symbol):
    url = f"{BASE_URL}?symbol={symbol}&token={API_KEY}"
    try:
        response = requests.get(url)
        response.raise_for_status()
        data = response.json()
        data["symbol"] = symbol
        data["fetched_at"] = int(time.time())
        return data
    except Exception as e:
        print(f"Error fetching {symbol}: {e}")
        return None

#Looping and Pushing to stream
while True:
    for symbol in SYMBOLS:
        quote = fetch_quote(symbol)
        if quote:
            print(f"Producing: {quote}")
            producer.send("stock-quotes", value=quote)
    time.sleep(6) # 60 call per minute, but we have 5 symbols  => wait 5s
    