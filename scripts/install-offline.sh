#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "${ROOT_DIR}/scripts/lib/config.sh"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
# shellcheck source=lib/offline.sh
source "${ROOT_DIR}/scripts/lib/offline.sh"
# shellcheck source=lib/offline_install.sh
source "${ROOT_DIR}/scripts/lib/offline_install.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/install-offline.sh --cache dist/offline-cache --config config/substrates.self-hosted.example.yaml --output out/ [--dry-run] [--force]

Validates an offline substrate cache, writes the normalized env/secrets contract,
and validates the result. It never downloads from the public internet.

In --dry-run mode this accepts either a P0 static contract skeleton or a p1-real
cache and skips cluster mutation. Without --dry-run, only p1-real caches are
installable.
EOF_USAGE
}

cache_dir=""
config_file=""
output_dir="out"
dry_run=false
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache)
      cache_dir="${2:-}"
      shift 2
      ;;
    --config)
      config_file="${2:-}"
      shift 2
      ;;
    --output)
      output_dir="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --force)
      force=true
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

[[ -n "${cache_dir}" ]] || die "--cache is required"
[[ -n "${config_file}" ]] || die "--config is required"

validate_offline_cache "${cache_dir}"
cache_mode="$(offline_cache_mode "${cache_dir}")"
install_mode="$(config_value "${config_file}" "mode" "self-hosted")"
write_env_contract_from_config "${config_file}" "${output_dir}" "install-offline" "${force}"
validate_env_contract "${output_dir}/substrate.env" "${output_dir}/substrate.secrets.env"

if [[ "${dry_run}" == "true" ]]; then
  if [[ "${cache_mode}" == "p0-contract" ]]; then
    info "dry-run: validated P0 static cache skeleton only; this is not a real offline install cache"
  else
    info "dry-run: validated p1-real cache contract; skipped cluster mutation"
  fi
else
  if [[ "${cache_mode}" == "p0-contract" ]]; then
    die "cannot perform live offline install from a P0 static cache skeleton; provide cacheMode: p1-real"
  fi
  case "${install_mode}" in
    self-hosted)
      run_p1_real_offline_install "${cache_dir}" "${output_dir}/substrate.env" "${output_dir}/substrate.secrets.env" "${output_dir}"
      ;;
    existing-cloud)
      run_p1_real_existing_cloud_validation "${cache_dir}" "${output_dir}/substrate.env" "${output_dir}/substrate.secrets.env" "${output_dir}"
      ;;
    *)
      die "mode must be self-hosted or existing-cloud"
      ;;
  esac
fi
