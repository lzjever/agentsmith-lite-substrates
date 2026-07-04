#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
# shellcheck source=lib/offline.sh
source "${ROOT_DIR}/scripts/lib/offline.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/doctor.sh --env out/substrate.env --secrets out/substrate.secrets.env [--offline-cache dist/offline-cache] [--dry-run] [--report out/doctor-report.json]

Substrate-only checks:
  K8s reachability/namespace, PostgreSQL URL/connectivity, S3 credential presence/probe,
  JuiceFS CSI/StorageClass/PVC/RWX contract, and offline cache completeness.

This script does not check app delivery smoke.
EOF_USAGE
}

env_file=""
secrets_file=""
offline_cache=""
report_file=""
dry_run=false

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
    --offline-cache)
      offline_cache="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --report)
      report_file="${2:-}"
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
if [[ -z "${report_file}" ]]; then
  report_file="$(dirname "${env_file}")/doctor-report.json"
fi

checks_json=()
failed=false

add_check() {
  local name="$1"
  local status="$2"
  local message="$3"
  local boundary="${4:-substrate}"
  checks_json+=("    {\"name\": \"$(json_escape "${name}")\", \"status\": \"$(json_escape "${status}")\", \"boundary\": \"$(json_escape "${boundary}")\", \"message\": \"$(json_escape "${message}")\"}")
  [[ "${status}" == "failed" ]] && failed=true
  printf '%s: %s - %s\n' "${name}" "${status}" "${message}"
}

if validate_output="$(validate_env_contract "${env_file}" "${secrets_file}" 2>&1)"; then
  printf '%s\n' "${validate_output}"
  add_check "env/secrets" "passed" "split substrate env contract is valid; secret values are redacted" "substrate-secret-boundary"
else
  printf '%s\n' "${validate_output}" >&2
  add_check "env/secrets" "failed" "split substrate env contract is invalid" "substrate-secret-boundary"
fi

namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
kubeconfig_path="$(env_value_or_empty "${env_file}" KUBECONFIG_PATH)"
kube_context="$(env_value_or_empty "${env_file}" KUBE_CONTEXT)"
postgres_url="$(env_value_or_empty "${secrets_file}" POSTGRES_APP_URL)"
s3_access="$(env_value_or_empty "${secrets_file}" S3_ACCESS_KEY)"
s3_secret="$(env_value_or_empty "${secrets_file}" S3_SECRET_KEY)"
juicefs_meta="$(env_value_or_empty "${secrets_file}" JUICEFS_META_URL)"

if [[ "${dry_run}" == "true" ]]; then
  add_check "k8s" "skipped" "dry-run: skipped live kubectl namespace checks for ${namespace}"
else
  if ! command -v kubectl >/dev/null 2>&1; then
    add_check "k8s" "failed" "kubectl not found; rerun with --dry-run for static checks only"
  else
    kubectl_args=()
    [[ -n "${kubeconfig_path}" ]] && kubectl_args+=(--kubeconfig "${kubeconfig_path}")
    [[ -n "${kube_context}" ]] && kubectl_args+=(--context "${kube_context}")
    if kubectl "${kubectl_args[@]}" get namespace "${namespace}" >/dev/null 2>&1; then
      add_check "k8s" "passed" "namespace ${namespace} is reachable"
    else
      add_check "k8s" "failed" "namespace ${namespace} is not reachable"
    fi
  fi
fi

if [[ "${postgres_url}" =~ ^postgres(ql)?:// ]]; then
  if [[ "${dry_run}" == "true" ]]; then
    add_check "postgres" "skipped" "dry-run: URL shape is valid; skipped live connection"
  elif command -v psql >/dev/null 2>&1; then
    if PGPASSWORD='' psql "${postgres_url}" -Atc 'select 1' >/dev/null 2>&1; then
      add_check "postgres" "passed" "product database accepted a simple query"
    else
      add_check "postgres" "failed" "product database did not accept a simple query"
    fi
  else
    add_check "postgres" "failed" "psql not found; cannot verify product database connectivity"
  fi
else
  add_check "postgres" "failed" "POSTGRES_APP_URL shape is invalid"
fi

if [[ -n "${s3_access}" && -n "${s3_secret}" ]]; then
  if [[ "${dry_run}" == "true" ]]; then
    add_check "s3" "skipped" "dry-run: S3 key presence confirmed; skipped read/write/delete probe" "substrate-csi-secret"
  else
    add_check "s3" "skipped" "live S3 probe is not implemented in this P0 script; credentials remain redacted" "substrate-csi-secret"
  fi
else
  add_check "s3" "failed" "S3_ACCESS_KEY and S3_SECRET_KEY must be present" "substrate-csi-secret"
fi

if [[ "${juicefs_meta}" =~ ^postgres(ql)?:// ]] \
  && [[ "$(env_value_or_empty "${env_file}" JUICEFS_CSI_DRIVER)" == "csi.juicefs.com" ]] \
  && [[ -n "$(env_value_or_empty "${env_file}" JUICEFS_STORAGE_CLASS)" ]] \
  && [[ -n "$(env_value_or_empty "${env_file}" JUICEFS_PVC_NAME)" ]]; then
  if [[ "${dry_run}" == "true" ]]; then
    add_check "juicefs-csi" "skipped" "dry-run: config present; skipped live CSI/StorageClass/PVC checks" "substrate-csi-secret"
    add_check "rwx" "skipped" "dry-run: skipped two-pod ReadWriteMany smoke"
  else
    add_check "juicefs-csi" "skipped" "live JuiceFS CSI validation is not implemented in this P0 script" "substrate-csi-secret"
    add_check "rwx" "skipped" "live RWX smoke is not implemented in this P0 script"
  fi
else
  add_check "juicefs-csi" "failed" "JuiceFS CSI config is incomplete" "substrate-csi-secret"
  add_check "rwx" "failed" "RWX cannot be checked without complete JuiceFS config"
fi

if [[ -n "${offline_cache}" ]]; then
  if offline_output="$(validate_offline_cache "${offline_cache}" 2>&1)"; then
    printf '%s\n' "${offline_output}"
    add_check "offline-cache" "passed" "offline cache has manifest, checksums, and digest-pinned image lock"
  else
    printf '%s\n' "${offline_output}" >&2
    add_check "offline-cache" "failed" "offline cache contract is invalid"
  fi
else
  add_check "offline-cache" "skipped" "no --offline-cache supplied"
fi

mkdir -p "$(dirname "${report_file}")"
overall="passed"
if [[ "${failed}" == "true" ]]; then
  overall="failed"
fi

{
  printf '{\n'
  printf '  "schemaVersion": "agentsmith-lite.substrate.doctor/v1",\n'
  printf '  "dryRun": %s,\n' "${dry_run}"
  printf '  "overallStatus": "%s",\n' "${overall}"
  printf '  "scope": "substrate-only",\n'
  printf '  "secretBoundary": "S3 and JuiceFS raw credentials are substrate/CSI scoped and redacted",\n'
  printf '  "checks": [\n'
  for i in "${!checks_json[@]}"; do
    printf '%s' "${checks_json[$i]}"
    if [[ "${i}" -lt $((${#checks_json[@]} - 1)) ]]; then
      printf ','
    fi
    printf '\n'
  done
  printf '  ]\n'
  printf '}\n'
} >"${report_file}"

info "doctor report written: ${report_file}"
[[ "${overall}" == "passed" ]] || exit 1
