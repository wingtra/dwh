#!/bin/bash
set -euo pipefail

PGDATA=${PGDATA:-/var/lib/postgresql/data}
SOCKET_DIR=/var/run/postgresql

# Initialize data directory on first boot (always, since container is ephemeral)
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "Initializing Postgres data directory at $PGDATA"
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  su postgres -c "/usr/lib/postgresql/${PG_MAJOR}/bin/initdb -D $PGDATA --auth=trust --no-locale --encoding=UTF8"
fi

mkdir -p "$SOCKET_DIR"
chown postgres:postgres "$SOCKET_DIR"

echo "Starting Postgres in background"
su postgres -c "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_ctl -D $PGDATA -l /tmp/pg.log -w start -o '-c unix_socket_directories=$SOCKET_DIR -c listen_addresses=\"\" -c max_connections=500'"

echo "Postgres ready. Running pipeline."
export PG_SOCKET_DIR=$SOCKET_DIR
exec python3 -m src.main
