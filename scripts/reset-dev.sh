#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "${ROOT_DIR}/scripts/lib/config.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/reset-dev.sh --config config/substrates.self-hosted.example.yaml --destroy-data [--output out] [--cache dist/offline-cache] [--dry-run]

Safety rules:
  - requires --destroy-data
  - config mode must be self-hosted
  - removes only generated local substrate outputs/cache in this P0 skeleton
EOF_USAGE
}

config_file=""
output_dir="out"
cache_dir="dist/offline-cache"
destroy_data=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      config_file="${2:-}"
      shift 2
      ;;
    --output)
      output_dir="${2:-}"
      shift 2
      ;;
    --cache)
      cache_dir="${2:-}"
      shift 2
      ;;
    --destroy-data)
      destroy_data=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${config_file}" ]] || die "--config is required"
[[ "${destroy_data}" == "true" ]] || die "--destroy-data is required for reset-dev"

mode="$(config_value "${config_file}" "mode" "")"
[[ "${mode}" == "self-hosted" ]] || die "reset-dev only supports self-hosted dev configs"

if [[ "${dry_run}" == "true" ]]; then
  info "dry-run: would remove ${output_dir} and ${cache_dir}"
  exit 0
fi

safe_remove_dir "${output_dir}"
safe_remove_dir "${cache_dir}"
info "removed generated dev substrate outputs: ${output_dir} ${cache_dir}"
