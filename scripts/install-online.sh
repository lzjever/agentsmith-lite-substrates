#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "${ROOT_DIR}/scripts/lib/config.sh"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/install-online.sh --config config/substrates.self-hosted.example.yaml --output out/ [--dry-run] [--force]

P0 validate-first installer. It writes the normalized env/secrets contract and
validates it. It does not yet install k3s, PostgreSQL, MinIO, or JuiceFS CSI.
EOF_USAGE
}

config_file=""
output_dir="out"
dry_run=false
force=false

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

[[ -n "${config_file}" ]] || die "--config is required"
write_env_contract_from_config "${config_file}" "${output_dir}" "install-online" "${force}"
validate_env_contract "${output_dir}/substrate.env" "${output_dir}/substrate.secrets.env"

if [[ "${dry_run}" == "true" ]]; then
  info "dry-run: skipped cluster mutation"
else
  info "validate-first: cluster mutation is intentionally not implemented in this P0 skeleton"
fi
