#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/offline_install.sh
source "${ROOT_DIR}/scripts/lib/offline_install.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/check-juicefs-rwx-write-read.sh --cache dist/offline-cache --env out/substrate.env

Runs the live JuiceFS RWX writer/reader check against the configured PVC using
cached kubectl and the digest-pinned rwx-check image from images/images.lock.
EOF_USAGE
}

cache_dir=""
env_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache)
      require_cli_value "$1" "${2-}"
      cache_dir="${2:-}"
      shift 2
      ;;
    --env)
      require_cli_value "$1" "${2-}"
      env_file="${2:-}"
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

[[ -n "${cache_dir}" ]] || die "--cache is required"
[[ -n "${env_file}" ]] || die "--env is required"

offline_install_check_juicefs_rwx_write_read "${cache_dir}" "${env_file}"
