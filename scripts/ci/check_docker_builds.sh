#!/usr/bin/env bash
set -euo pipefail

build_count=0
for source_dir in pipelines/sources/*; do
  [[ -d "${source_dir}" ]] || continue
  if [[ ! -f "${source_dir}/Dockerfile" ]]; then
    continue
  fi

  source_name="$(basename "${source_dir}")"
  image_tag="dwh-${source_name}:ci"
  echo "Building ${image_tag} from ${source_dir}"
  docker build \
    --file "${source_dir}/Dockerfile" \
    --tag "${image_tag}" \
    "${source_dir}"
  build_count=$((build_count + 1))
done

if [[ ${build_count} -eq 0 ]]; then
  echo "No source Dockerfiles found."
fi

if [[ -f dbt/Dockerfile ]]; then
  echo "Building dwh-dbt:ci from dbt"
  docker build \
    --file dbt/Dockerfile \
    --tag dwh-dbt:ci \
    dbt
fi
