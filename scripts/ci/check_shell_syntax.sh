#!/usr/bin/env bash
set -euo pipefail

scripts=()
while IFS= read -r script; do
  scripts+=("${script}")
done < <(find pipelines scripts dbt -type f -name "*.sh" -print | sort)

if [[ ${#scripts[@]} -eq 0 ]]; then
  echo "No shell scripts found."
  exit 0
fi

bash -n "${scripts[@]}"
