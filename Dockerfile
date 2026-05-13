ARG PG_VERSION=16
FROM postgres:${PG_VERSION}-bookworm

# Install Python 3 + pip + SSH client (for SCP to Odoo.sh)
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Install Python deps in a venv to avoid clashing with Debian's PEP 668 lock
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY .dlt/config.toml ./.dlt/config.toml
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["/entrypoint.sh"]
