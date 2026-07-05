#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/preflight.sh --env out/substrate.env --secrets out/substrate.secrets.env [--offline-cache dist/offline-cache] [--report out/doctor-report.json]

Substrate-only preflight delegates to scripts/doctor.sh --dry-run for static
env/secrets, JuiceFS/RWX contract, and optional offline-cache validation.
Use --cache as an alias for --offline-cache.

Preflight does not run live kubectl, psql, S3, RWX, Helm, k3s install, image
import, download, app, Botified, or API smoke checks.
EOF_USAGE
}

doctor_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env|--secrets|--report)
      [[ $# -ge 2 && -n "${2:-}" ]] || die "$1 requires a value"
      doctor_args+=("$1" "$2")
      shift 2
      ;;
    --offline-cache|--cache)
      [[ $# -ge 2 && -n "${2:-}" ]] || die "$1 requires a value"
      doctor_args+=(--offline-cache "$2")
      shift 2
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

exec "${ROOT_DIR}/scripts/doctor.sh" "${doctor_args[@]}" --dry-run
