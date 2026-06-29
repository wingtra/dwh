#!/usr/bin/env bash
set -euo pipefail

blocked_paths=(
  ".env"
  ".mcp.json"
  ".obsidian"
  ".claude"
  "tmp"
  "debug sqls"
)

for path in "${blocked_paths[@]}"; do
  if [[ -e "${path}" ]]; then
    echo "Blocked local artifact found: ${path}" >&2
    exit 1
  fi
done

blocked_patterns=(
  "*.pem"
  "*.key"
  "*.pub"
  "*.credentials"
  "*.token"
  "dump-summary.csv"
  "odoo18-dump-summary.csv"
  "*_dump_summary.csv"
  "*_export.csv"
  "*_comparison.csv"
)

for pattern in "${blocked_patterns[@]}"; do
  while IFS= read -r match; do
    [[ -n "${match}" ]] || continue
    echo "Blocked local artifact found: ${match}" >&2
    exit 1
  done < <(find . -path ./.git -prune -o -name "${pattern}" -print)
done

while IFS= read -r env_file; do
  case "${env_file}" in
    *.env.example|*/config.env.example) continue ;;
  esac
  echo "Non-example env file is not allowed in Git: ${env_file}" >&2
  exit 1
done < <(find . -path ./.git -prune -o -type f \( -name "*.env" -o -name ".env.*" -o -name "config.env" \) -print)

if grep -RIl --exclude-dir=.git --exclude='*.md' --exclude='check_no_local_artifacts.sh' \
    -e 'BEGIN OPENSSH PRIVATE KEY' \
    -e 'BEGIN RSA PRIVATE KEY' \
    -e 'BEGIN EC PRIVATE KEY' \
    -e 'BEGIN PRIVATE KEY' \
    . >/tmp/secret_matches.txt; then
  echo "Private key material found:" >&2
  sed 's/^/  /' /tmp/secret_matches.txt >&2
  exit 1
fi
