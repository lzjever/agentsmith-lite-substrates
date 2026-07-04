#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/validate-env.sh --env out/substrate.env --secrets out/substrate.secrets.env

Validates the AgentSmith Lite substrate env contract:
  - substrate.env may contain only non-secret config
  - substrate.secrets.env may contain only substrate/CSI secret keys
  - secret values are never printed; stable fingerprints are printed instead
EOF_USAGE
}

env_file=""
secrets_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      env_file="${2:-}"
      shift 2
      ;;
    --secrets)
      secrets_file="${2:-}"
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

[[ -n "${env_file}" ]] || die "--env is required"
[[ -n "${secrets_file}" ]] || die "--secrets is required"

validate_env_contract "${env_file}" "${secrets_file}"
