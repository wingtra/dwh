#!/bin/sh
set -eu

DBT_PROJECT_DIR="${DBT_PROJECT_DIR:-/app/dbt}"
DBT_PROFILES_DIR="${DBT_PROFILES_DIR:-/app/dbt}"
DBT_COMMAND="${DBT_COMMAND:-build}"
DBT_SELECTOR="${DBT_SELECTOR:-weekly}"

set -- dbt "${DBT_COMMAND}" \
  --project-dir "${DBT_PROJECT_DIR}" \
  --profiles-dir "${DBT_PROFILES_DIR}"

if [ -n "${DBT_SELECT:-}" ]; then
  set -- "$@" --select "${DBT_SELECT}"
elif [ -n "${DBT_SELECTOR:-}" ]; then
  set -- "$@" --selector "${DBT_SELECTOR}"
fi

if [ -n "${DBT_EXCLUDE:-}" ]; then
  set -- "$@" --exclude "${DBT_EXCLUDE}"
fi

if [ "${DBT_FULL_REFRESH:-false}" = "true" ]; then
  set -- "$@" --full-refresh
fi

exec "$@"
