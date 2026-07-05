#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
# shellcheck source=lib/offline.sh
source "${ROOT_DIR}/scripts/lib/offline.sh"
# shellcheck source=lib/postgres.sh
source "${ROOT_DIR}/scripts/lib/postgres.sh"
# shellcheck source=lib/s3_probe.sh
source "${ROOT_DIR}/scripts/lib/s3_probe.sh"
# shellcheck source=lib/rwx_smoke.sh
source "${ROOT_DIR}/scripts/lib/rwx_smoke.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/doctor.sh --env out/substrate.env --secrets out/substrate.secrets.env [--offline-cache dist/offline-cache] [--s3-probe-image image@sha256:<digest>] [--rwx-smoke-image image@sha256:<digest>] [--dry-run] [--report out/doctor-report.json]

Substrate-only checks:
  K8s reachability/namespace, PostgreSQL URL/connectivity, S3 credential presence/probe,
  JuiceFS CSI/StorageClass/PVC/RWX contract, and offline cache completeness.

--dry-run proves static contracts only. Live mode marks unverifiable kubectl,
cluster, psql, S3, JuiceFS, or RWX checks partial or failed; skipped live checks
are never treated as a full pass.

This script does not check app delivery smoke.
EOF_USAGE
}

env_file=""
secrets_file=""
offline_cache=""
s3_probe_image=""
rwx_smoke_image=""
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
    --s3-probe-image)
      s3_probe_image="${2:-}"
      shift 2
      ;;
    --rwx-smoke-image)
      rwx_smoke_image="${2:-}"
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
partial=false
resolved_s3_probe_image=""
doctor_s3_probe_image_error=""
resolved_rwx_smoke_image=""
doctor_rwx_smoke_image_error=""

add_check() {
  local name="$1"
  local status="$2"
  local message="$3"
  local boundary="${4:-substrate}"
  checks_json+=("    {\"name\": \"$(json_escape "${name}")\", \"status\": \"$(json_escape "${status}")\", \"boundary\": \"$(json_escape "${boundary}")\", \"message\": \"$(json_escape "${message}")\"}")
  case "${status}" in
    failed)
      failed=true
      ;;
    partial)
      partial=true
      ;;
  esac
  printf '%s: %s - %s\n' "${name}" "${status}" "${message}"
}

doctor_check_postgres_url() {
  local name="$1"
  local key="$2"
  local url="$3"
  local passed_message="$4"
  local failed_message="$5"
  local partial_message="$6"
  local prefix="doctor_${name//-/_}"

  if [[ ! "${url}" =~ ^postgres(ql)?:// ]]; then
    add_check "${name}" "failed" "${key} shape is invalid"
    return 0
  fi

  if ! postgres_parse_url "${url}" "${key}" "${prefix}" >/dev/null 2>&1; then
    add_check "${name}" "failed" "${key} is invalid or incomplete"
    return 0
  fi

  if [[ "${dry_run}" == "true" ]]; then
    add_check "${name}" "passed" "dry-run static: ${key} shape is valid; skipped live query"
  elif command -v psql >/dev/null 2>&1; then
    local password_var host_var port_var user_var database_var
    local password host port user database
    password_var="${prefix}_PASSWORD"
    host_var="${prefix}_HOST"
    port_var="${prefix}_PORT"
    user_var="${prefix}_USER"
    database_var="${prefix}_DATABASE"
    password="${!password_var}"
    host="${!host_var}"
    port="${!port_var}"
    user="${!user_var}"
    database="${!database_var}"
    if PGPASSWORD="${password}" psql -h "${host}" -p "${port}" -U "${user}" -d "${database}" -Atc 'select 1' >/dev/null 2>&1; then
      add_check "${name}" "passed" "${passed_message}"
    else
      add_check "${name}" "failed" "${failed_message}"
    fi
  else
    add_check "${name}" "partial" "${partial_message}"
  fi
}

doctor_validate_s3_probe_image_ref() {
  local image_ref="$1"
  if [[ ! "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    doctor_s3_probe_image_error="S3 probe image must be digest-pinned with @sha256:<64 lowercase hex>"
    return 1
  fi
  if is_app_owned_image_ref "${image_ref}"; then
    doctor_s3_probe_image_error="S3 probe image must not reference app-owned images"
    return 1
  fi
  return 0
}

doctor_resolve_s3_probe_image() {
  local lock_file image_ref
  resolved_s3_probe_image=""
  doctor_s3_probe_image_error=""

  if [[ -n "${s3_probe_image}" ]]; then
    doctor_validate_s3_probe_image_ref "${s3_probe_image}" || return 1
    resolved_s3_probe_image="${s3_probe_image}"
    return 0
  fi

  if [[ -n "${offline_cache}" ]]; then
    lock_file="${offline_cache}/images/images.lock"
    if [[ ! -f "${lock_file}" ]]; then
      doctor_s3_probe_image_error="S3 probe image is required for live S3 check; offline cache images.lock was not readable"
      return 1
    fi
    if ! image_ref="$(images_lock_image_ref "${lock_file}" "minio-client" 2>/dev/null)"; then
      doctor_s3_probe_image_error="S3 probe image is required for live S3 check; offline cache images.lock is missing name: minio-client"
      return 1
    fi
    doctor_validate_s3_probe_image_ref "${image_ref}" || return 1
    resolved_s3_probe_image="${image_ref}"
    return 0
  fi

  doctor_s3_probe_image_error="S3 probe image is required for live S3 check; supply --offline-cache with images.lock name: minio-client or --s3-probe-image"
  return 1
}

doctor_validate_rwx_smoke_image_ref() {
  local image_ref="$1"
  if [[ ! "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    doctor_rwx_smoke_image_error="RWX smoke image must be digest-pinned with @sha256:<64 lowercase hex>"
    return 1
  fi
  if is_app_owned_image_ref "${image_ref}"; then
    doctor_rwx_smoke_image_error="RWX smoke image must not reference app-owned images"
    return 1
  fi
  return 0
}

doctor_resolve_rwx_smoke_image() {
  local lock_file image_ref
  resolved_rwx_smoke_image=""
  doctor_rwx_smoke_image_error=""

  if [[ -n "${rwx_smoke_image}" ]]; then
    doctor_validate_rwx_smoke_image_ref "${rwx_smoke_image}" || return 1
    resolved_rwx_smoke_image="${rwx_smoke_image}"
    return 0
  fi

  if [[ -n "${offline_cache}" ]]; then
    lock_file="${offline_cache}/images/images.lock"
    if [[ ! -f "${lock_file}" ]]; then
      doctor_rwx_smoke_image_error="RWX smoke image is required after PVC Bound; offline cache images.lock was not readable"
      return 1
    fi
    if ! image_ref="$(images_lock_image_ref "${lock_file}" "rwx-smoke" 2>/dev/null)"; then
      doctor_rwx_smoke_image_error="RWX smoke image is required after PVC Bound; offline cache images.lock is missing name: rwx-smoke"
      return 1
    fi
    doctor_validate_rwx_smoke_image_ref "${image_ref}" || return 1
    resolved_rwx_smoke_image="${image_ref}"
    return 0
  fi

  doctor_rwx_smoke_image_error="RWX smoke image is required after PVC Bound; supply --offline-cache with images.lock name: rwx-smoke or --rwx-smoke-image"
  return 1
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
s3_endpoint="$(env_value_or_empty "${env_file}" S3_ENDPOINT)"
s3_region="$(env_value_or_empty "${env_file}" S3_REGION)"
s3_bucket="$(env_value_or_empty "${env_file}" S3_BUCKET)"
s3_force_path_style="$(env_value_or_empty "${env_file}" S3_FORCE_PATH_STYLE)"
s3_access="$(env_value_or_empty "${secrets_file}" S3_ACCESS_KEY)"
s3_secret="$(env_value_or_empty "${secrets_file}" S3_SECRET_KEY)"
juicefs_meta="$(env_value_or_empty "${secrets_file}" JUICEFS_META_URL)"
juicefs_csi_driver="$(env_value_or_empty "${env_file}" JUICEFS_CSI_DRIVER)"
juicefs_secret_name="$(env_value_or_empty "${env_file}" JUICEFS_SECRET_NAME)"
juicefs_storage_class="$(env_value_or_empty "${env_file}" JUICEFS_STORAGE_CLASS)"
juicefs_pvc_name="$(env_value_or_empty "${env_file}" JUICEFS_PVC_NAME)"

kubectl_args=()
[[ -n "${kubeconfig_path}" ]] && kubectl_args+=(--kubeconfig "${kubeconfig_path}")
[[ -n "${kube_context}" ]] && kubectl_args+=(--context "${kube_context}")
kubectl_cmd=()
kubectl_available=false
cluster_reachable=false
kubeconfig_unreadable=false

if [[ "${dry_run}" == "true" ]]; then
  add_check "k8s" "passed" "dry-run static: namespace is configured as ${namespace}"
else
  if [[ -n "${kubeconfig_path}" && ( ! -f "${kubeconfig_path}" || ! -r "${kubeconfig_path}" ) ]]; then
    kubeconfig_unreadable=true
    add_check "k8s" "failed" "KUBECONFIG_PATH is not readable: ${kubeconfig_path}"
  elif [[ -n "${KUBECTL_BIN:-}" ]]; then
    if [[ -x "${KUBECTL_BIN}" ]]; then
      kubectl_cmd=("${KUBECTL_BIN}")
      kubectl_available=true
    else
      add_check "k8s" "failed" "configured KUBECTL_BIN is not executable"
    fi
  elif command -v kubectl >/dev/null 2>&1; then
    kubectl_cmd=(kubectl)
    kubectl_available=true
  else
    add_check "k8s" "partial" "kubectl not found; live namespace reachability was not verified"
  fi

  if [[ "${kubectl_available}" == "true" ]]; then
    if "${kubectl_cmd[@]}" "${kubectl_args[@]}" get namespace "${namespace}" >/dev/null 2>&1; then
      cluster_reachable=true
      add_check "k8s" "passed" "namespace ${namespace} is reachable"
    else
      add_check "k8s" "failed" "namespace ${namespace} is not reachable"
    fi
  fi
fi

doctor_check_postgres_url \
  "postgres-app" \
  "POSTGRES_APP_URL" \
  "${postgres_url}" \
  "app database accepted a simple query" \
  "app database did not accept a simple query" \
  "psql not found; app database connectivity was not verified"

doctor_check_postgres_url \
  "postgres-juicefs-meta" \
  "JUICEFS_META_URL" \
  "${juicefs_meta}" \
  "JuiceFS metadata database accepted a simple query" \
  "JuiceFS metadata database did not accept a simple query" \
  "psql not found; JuiceFS metadata database connectivity was not verified"

if [[ -n "${s3_endpoint}" && -n "${s3_region}" && -n "${s3_bucket}" && -n "${s3_force_path_style}" && -n "${s3_access}" && -n "${s3_secret}" ]]; then
  if [[ "${dry_run}" == "true" ]]; then
    add_check "s3" "passed" "dry-run static: S3 endpoint, region, bucket, path-style, and key presence are valid; skipped read/write/delete probe" "substrate-csi-secret"
  elif [[ "${kubeconfig_unreadable}" == "true" ]]; then
    add_check "s3" "partial" "KUBECONFIG_PATH is not readable; live S3 read/write/delete probe was not verified" "substrate-csi-secret"
  elif [[ "${kubectl_available}" != "true" ]]; then
    add_check "s3" "partial" "kubectl not found; live S3 read/write/delete probe was not verified" "substrate-csi-secret"
  elif [[ "${cluster_reachable}" != "true" ]]; then
    add_check "s3" "partial" "cluster namespace is not reachable; live S3 read/write/delete probe was not verified" "substrate-csi-secret"
  elif doctor_resolve_s3_probe_image; then
    if s3_probe_output="$(s3_probe_run "${namespace}" "${resolved_s3_probe_image}" "${s3_endpoint}" "${s3_region}" "${s3_bucket}" "${s3_force_path_style}" "${s3_access}" "${s3_secret}" "${kubectl_cmd[0]}" "${kubectl_args[@]}" 2>&1)"; then
      printf '%s\n' "${s3_probe_output}"
      add_check "s3" "passed" "live S3 read/write/delete probe passed" "substrate-csi-secret"
    else
      printf '%s\n' "${s3_probe_output}" >&2
      add_check "s3" "failed" "live S3 read/write/delete probe failed; credentials and endpoint remain redacted" "substrate-csi-secret"
    fi
  else
    add_check "s3" "failed" "${doctor_s3_probe_image_error}" "substrate-csi-secret"
  fi
else
  add_check "s3" "failed" "S3 endpoint, region, bucket, path-style, S3_ACCESS_KEY, and S3_SECRET_KEY must be present" "substrate-csi-secret"
fi

if [[ "${juicefs_meta}" =~ ^postgres(ql)?:// ]]; then
  if juicefs_output="$("${ROOT_DIR}/scripts/validate-juicefs-contract.sh" --env "${env_file}" --secrets "${secrets_file}" 2>&1)"; then
    printf '%s\n' "${juicefs_output}"
    if [[ "${dry_run}" == "true" ]]; then
      add_check "juicefs-csi" "passed" "dry-run static: rendered JuiceFS Secret, StorageClass, and PVC contract is valid" "substrate-csi-secret"
      add_check "rwx" "passed" "dry-run static: PVC contract requests ReadWriteMany; skipped two-Job RWX smoke"
    elif [[ "${kubeconfig_unreadable}" == "true" ]]; then
      add_check "juicefs-csi" "partial" "KUBECONFIG_PATH is not readable; live JuiceFS Secret, StorageClass, and PVC were not verified" "substrate-csi-secret"
      add_check "rwx" "partial" "live two-job ReadWriteMany smoke requires a readable KUBECONFIG_PATH; RWX was not verified"
    elif [[ "${kubectl_available}" != "true" ]]; then
      add_check "juicefs-csi" "partial" "kubectl not found; live JuiceFS Secret, StorageClass, and PVC were not verified" "substrate-csi-secret"
      add_check "rwx" "partial" "live two-job ReadWriteMany smoke requires kubectl; RWX was not verified"
    elif [[ "${cluster_reachable}" != "true" ]]; then
      add_check "juicefs-csi" "partial" "cluster namespace is not reachable; live JuiceFS resources were not verified" "substrate-csi-secret"
      add_check "rwx" "partial" "live two-job ReadWriteMany smoke requires a reachable namespace; RWX was not verified"
    elif ! "${kubectl_cmd[@]}" "${kubectl_args[@]}" get csidriver "${juicefs_csi_driver}" >/dev/null 2>&1; then
      add_check "juicefs-csi" "failed" "live JuiceFS CSIDriver ${juicefs_csi_driver} is missing" "substrate-csi-secret"
      add_check "rwx" "failed" "RWX was not verified because live JuiceFS CSIDriver ${juicefs_csi_driver} is missing"
    elif "${kubectl_cmd[@]}" "${kubectl_args[@]}" get storageclass "${juicefs_storage_class}" >/dev/null 2>&1 \
      && "${kubectl_cmd[@]}" "${kubectl_args[@]}" -n "${namespace}" get secret "${juicefs_secret_name}" >/dev/null 2>&1 \
      && "${kubectl_cmd[@]}" "${kubectl_args[@]}" -n "${namespace}" get pvc "${juicefs_pvc_name}" >/dev/null 2>&1; then
      pvc_phase=""
      if pvc_phase="$("${kubectl_cmd[@]}" "${kubectl_args[@]}" -n "${namespace}" get pvc "${juicefs_pvc_name}" -o jsonpath={.status.phase} 2>/dev/null)" \
        && [[ -n "${pvc_phase}" ]]; then
        case "${pvc_phase}" in
          Bound)
            add_check "juicefs-csi" "passed" "live JuiceFS PVC phase is Bound" "substrate-csi-secret"
            if doctor_resolve_rwx_smoke_image; then
              if rwx_output="$(rwx_smoke_run "${namespace}" "${juicefs_pvc_name}" "${resolved_rwx_smoke_image}" "${kubectl_cmd[0]}" "${kubectl_args[@]}" 2>&1)"; then
                printf '%s\n' "${rwx_output}"
                add_check "rwx" "passed" "live two-job ReadWriteMany smoke passed against PVC ${juicefs_pvc_name}"
              else
                printf '%s\n' "${rwx_output}" >&2
                add_check "rwx" "failed" "live two-job ReadWriteMany smoke failed; see doctor output for sanitized Job logs"
              fi
            else
              add_check "rwx" "failed" "${doctor_rwx_smoke_image_error}"
            fi
            ;;
          Pending|Lost)
            add_check "juicefs-csi" "failed" "live JuiceFS PVC phase is ${pvc_phase}, expected Bound" "substrate-csi-secret"
            add_check "rwx" "failed" "RWX was not verified because live JuiceFS PVC phase is ${pvc_phase}, expected Bound"
            ;;
          *)
            add_check "juicefs-csi" "failed" "live JuiceFS PVC phase is not Bound" "substrate-csi-secret"
            add_check "rwx" "failed" "RWX was not verified because live JuiceFS PVC phase is not Bound"
            ;;
        esac
      else
        add_check "juicefs-csi" "failed" "live JuiceFS PVC phase could not be read" "substrate-csi-secret"
        add_check "rwx" "failed" "RWX was not verified because live JuiceFS PVC phase could not be read"
      fi
    else
      add_check "juicefs-csi" "failed" "live JuiceFS StorageClass, Secret, or PVC is missing" "substrate-csi-secret"
      add_check "rwx" "failed" "RWX was not verified because live JuiceFS StorageClass, Secret, or PVC is missing"
    fi
  else
    printf '%s\n' "${juicefs_output}" >&2
    add_check "juicefs-csi" "failed" "rendered JuiceFS CSI static contract is invalid" "substrate-csi-secret"
    add_check "rwx" "failed" "RWX cannot be checked without a valid JuiceFS PVC contract"
  fi
else
  add_check "juicefs-csi" "failed" "JUICEFS_META_URL shape is invalid" "substrate-csi-secret"
  add_check "rwx" "failed" "RWX cannot be checked without complete JuiceFS config"
fi

if [[ -n "${offline_cache}" ]]; then
  if offline_output="$(validate_offline_cache "${offline_cache}" 2>&1)"; then
    printf '%s\n' "${offline_output}"
    cache_mode="$(offline_cache_mode "${offline_cache}")"
    if [[ "${cache_mode}" == "p0-contract" ]]; then
      if [[ "${dry_run}" == "true" ]]; then
        add_check "offline-cache" "passed" "P0 static cache skeleton is valid; it is not a real offline install cache"
      else
        add_check "offline-cache" "partial" "P0 static cache skeleton is valid but cannot support a real offline install"
      fi
    else
      add_check "offline-cache" "passed" "p1-real offline cache contract is complete and archive checksums were verified"
    fi
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
elif [[ "${partial}" == "true" ]]; then
  overall="partial"
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
case "${overall}" in
  passed)
    exit 0
    ;;
  partial)
    exit 2
    ;;
  failed)
    exit 1
    ;;
esac
