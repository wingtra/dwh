FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . /app/dbt/
RUN chmod +x /app/dbt/docker/entrypoint.sh

ENTRYPOINT ["/app/dbt/docker/entrypoint.sh"]
