FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/__init__.py ./src/__init__.py
COPY src/revolut_raw_loader.py ./src/revolut_raw_loader.py

ENTRYPOINT ["python", "-m", "src.revolut_raw_loader"]
