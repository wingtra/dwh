#!/usr/bin/env bash
set -euo pipefail

unexpected=()
for path in src infra docker .dlt Dockerfile requirements.txt; do
  if [[ -e "${path}" ]]; then
    unexpected+=("${path}")
  fi
done

if [[ ${#unexpected[@]} -gt 0 ]]; then
  printf 'Root-level pipeline files are not allowed:\n' >&2
  printf '  %s\n' "${unexpected[@]}" >&2
  printf '\nPut source-owned ingestion code under pipelines/sources/<source>/.\n' >&2
  exit 1
fi

if [[ ! -d pipelines/sources ]]; then
  echo "Missing pipelines/sources directory." >&2
  exit 1
fi

for source_dir in pipelines/sources/*; do
  [[ -d "${source_dir}" ]] || continue
  source_name="$(basename "${source_dir}")"
  for required in README.md src infra docs; do
    if [[ ! -e "${source_dir}/${required}" ]]; then
      echo "Source pipeline ${source_name} is missing ${required}." >&2
      exit 1
    fi
  done
done
