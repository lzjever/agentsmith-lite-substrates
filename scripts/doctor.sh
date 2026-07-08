#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
# shellcheck source=lib/offline.sh
source "${ROOT_DIR}/scripts/lib/offline.sh"
# shellcheck source=lib/postgres.sh
source "${ROOT_DIR}/scripts/lib/postgres.sh"
# shellcheck source=lib/postgres_probe.sh
source "${ROOT_DIR}/scripts/lib/postgres_probe.sh"
# shellcheck source=lib/s3_probe.sh
source "${ROOT_DIR}/scripts/lib/s3_probe.sh"
# shellcheck source=lib/rwx_write_read_check.sh
source "${ROOT_DIR}/scripts/lib/rwx_write_read_check.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/doctor.sh --env out/substrate.env --secrets out/substrate.secrets.env [--offline-cache dist/offline-cache] [--postgres-probe-image image@sha256:<digest>] [--s3-probe-image image@sha256:<digest>] [--rwx-check-image image@sha256:<digest>] [--dry-run]

Substrate-only checks:
  K8s reachability/namespace, PostgreSQL URL/connectivity, S3 credential presence/probe,
  JuiceFS CSI/StorageClass/PVC/RWX contract, and offline cache completeness.

--dry-run proves static contracts only. Live mode marks unverifiable kubectl,
cluster, Postgres probe, S3, JuiceFS, or RWX checks partial or failed; skipped
live checks are never treated as a full pass.

This script does not check app deployment, API, or task runtime behavior.
It prints "name: status - message" lines and exits 0 for passed, 2 for
partial, or 1 for failed.
EOF_USAGE
}

env_file=""
secrets_file=""
offline_cache=""
postgres_probe_image=""
s3_probe_image=""
rwx_check_image=""
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      require_cli_value "$1" "${2-}"
      env_file="${2:-}"
      shift 2
      ;;
    --secrets)
      require_cli_value "$1" "${2-}"
      secrets_file="${2:-}"
      shift 2
      ;;
    --offline-cache)
      require_cli_value "$1" "${2-}"
      offline_cache="${2:-}"
      shift 2
      ;;
    --postgres-probe-image)
      require_cli_value "$1" "${2-}"
      postgres_probe_image="${2:-}"
      shift 2
      ;;
    --s3-probe-image)
      require_cli_value "$1" "${2-}"
      s3_probe_image="${2:-}"
      shift 2
      ;;
    --rwx-check-image)
      require_cli_value "$1" "${2-}"
      rwx_check_image="${2:-}"
      shift 2
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

[[ -n "${env_file}" ]] || die "--env is required"
[[ -n "${secrets_file}" ]] || die "--secrets is required"

failed=false
partial=false
resolved_postgres_probe_image=""
doctor_postgres_probe_image_error=""
resolved_s3_probe_image=""
doctor_s3_probe_image_error=""
resolved_rwx_check_image=""
doctor_rwx_check_image_error=""

add_check() {
  local name="$1"
  local status="$2"
  local message="$3"
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
  local prefix="doctor_${name//-/_}"

  if [[ "${key}" == "JUICEFS_META_URL" && ! "${url}" =~ ^postgres:// ]]; then
    add_check "${name}" "failed" "${key} shape is invalid"
    return 0
  fi
  if [[ "${key}" != "JUICEFS_META_URL" && ! "${url}" =~ ^postgres(ql)?:// ]]; then
    add_check "${name}" "failed" "${key} shape is invalid"
    return 0
  fi

  if ! postgres_parse_url "${url}" "${key}" "${prefix}" >/dev/null 2>&1; then
    add_check "${name}" "failed" "${key} is invalid or incomplete"
    return 0
  fi

  if [[ "${dry_run}" == "true" ]]; then
    add_check "${name}" "passed" "dry-run static: ${key} shape is valid; skipped live query"
    return 0
  fi

  if [[ "${kubeconfig_unreadable}" == "true" ]]; then
    add_check "${name}" "partial" "configured KUBECONFIG_PATH is not readable; live ${key} query was not verified"
  elif [[ "${kubectl_available}" != "true" ]]; then
    add_check "${name}" "partial" "kubectl not found; live ${key} query was not verified"
  elif [[ "${cluster_reachable}" != "true" ]]; then
    add_check "${name}" "partial" "cluster namespace is not reachable; live ${key} query was not verified"
  elif doctor_resolve_postgres_probe_image; then
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
    local postgres_probe_output
    if postgres_probe_output="$(postgres_probe_run "${namespace}" "${name}" "${resolved_postgres_probe_image}" "${host}" "${port}" "${user}" "${password}" "${database}" "${kubectl_cmd[0]}" "${kubectl_args[@]}" 2>&1)"; then
      printf '%s\n' "${postgres_probe_output}"
      add_check "${name}" "passed" "${passed_message}"
    else
      printf '%s\n' "${postgres_probe_output}" >&2
      add_check "${name}" "failed" "${failed_message}"
    fi
  else
    add_check "${name}" "failed" "${doctor_postgres_probe_image_error}"
  fi
}

doctor_validate_postgres_probe_image_ref() {
  local image_ref="$1"
  if [[ ! "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    doctor_postgres_probe_image_error="Postgres probe image must be digest-pinned with @sha256:<64 lowercase hex>"
    return 1
  fi
  if is_app_owned_image_ref "${image_ref}"; then
    doctor_postgres_probe_image_error="Postgres probe image must not reference app-owned images"
    return 1
  fi
  return 0
}

doctor_resolve_postgres_probe_image() {
  local lock_file image_ref
  resolved_postgres_probe_image=""
  doctor_postgres_probe_image_error=""

  if [[ -n "${postgres_probe_image}" ]]; then
    doctor_validate_postgres_probe_image_ref "${postgres_probe_image}" || return 1
    resolved_postgres_probe_image="${postgres_probe_image}"
    return 0
  fi

  if [[ -n "${offline_cache}" ]]; then
    lock_file="${offline_cache}/images/images.lock"
    if [[ ! -f "${lock_file}" ]]; then
      doctor_postgres_probe_image_error="Postgres probe image is required for live Postgres check; offline cache images.lock was not readable"
      return 1
    fi
    if ! image_ref="$(images_lock_image_ref "${lock_file}" "postgres" 2>/dev/null)"; then
      doctor_postgres_probe_image_error="Postgres probe image is required for live Postgres check; offline cache images.lock is missing name: postgres"
      return 1
    fi
    doctor_validate_postgres_probe_image_ref "${image_ref}" || return 1
    resolved_postgres_probe_image="${image_ref}"
    return 0
  fi

  doctor_postgres_probe_image_error="Postgres probe image is required for live Postgres check; supply --offline-cache with images.lock name: postgres or --postgres-probe-image"
  return 1
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

doctor_validate_rwx_check_image_ref() {
  local image_ref="$1"
  if [[ ! "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]]; then
    doctor_rwx_check_image_error="RWX check image must be digest-pinned with @sha256:<64 lowercase hex>"
    return 1
  fi
  if is_app_owned_image_ref "${image_ref}"; then
    doctor_rwx_check_image_error="RWX check image must not reference app-owned images"
    return 1
  fi
  return 0
}

doctor_resolve_rwx_check_image() {
  local lock_file image_ref
  resolved_rwx_check_image=""
  doctor_rwx_check_image_error=""

  if [[ -n "${rwx_check_image}" ]]; then
    doctor_validate_rwx_check_image_ref "${rwx_check_image}" || return 1
    resolved_rwx_check_image="${rwx_check_image}"
    return 0
  fi

  if [[ -n "${offline_cache}" ]]; then
    lock_file="${offline_cache}/images/images.lock"
    if [[ ! -f "${lock_file}" ]]; then
      doctor_rwx_check_image_error="RWX check image is required after PVC Bound; offline cache images.lock was not readable"
      return 1
    fi
    if ! image_ref="$(images_lock_image_ref "${lock_file}" "rwx-check" 2>/dev/null)"; then
      doctor_rwx_check_image_error="RWX check image is required after PVC Bound; offline cache images.lock is missing name: rwx-check"
      return 1
    fi
    doctor_validate_rwx_check_image_ref "${image_ref}" || return 1
    resolved_rwx_check_image="${image_ref}"
    return 0
  fi

  doctor_rwx_check_image_error="RWX check image is required after PVC Bound; supply --offline-cache with images.lock name: rwx-check or --rwx-check-image"
  return 1
}

doctor_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

doctor_kubectl_jsonpath() {
  local value
  value="$("${kubectl_cmd[@]}" "${kubectl_args[@]}" "$@" 2>/dev/null)" || return 1
  printf '%s' "${value}"
}

doctor_live_value_matches() {
  local label="$1"
  local expected="$2"
  shift 2
  local observed

  if ! observed="$(doctor_kubectl_jsonpath "$@")" || [[ -z "${observed}" ]]; then
    doctor_juicefs_contract_error="live JuiceFS ${label} could not be read"
    return 1
  fi
  if [[ "${observed}" != "${expected}" ]]; then
    doctor_juicefs_contract_error="live JuiceFS ${label} does not match substrate contract"
    return 1
  fi
  return 0
}

doctor_live_named_value_matches() {
  local label="$1"
  local expected_name="$2"
  local expected="$3"
  shift 3
  local observed

  if ! observed="$(doctor_kubectl_jsonpath "$@")" || [[ -z "${observed}" ]]; then
    doctor_juicefs_contract_error="live JuiceFS ${label} could not be read"
    return 1
  fi
  if [[ "${observed}" != "${expected}" ]]; then
    doctor_juicefs_contract_error="live JuiceFS ${label} does not match ${expected_name}"
    return 1
  fi
  return 0
}

doctor_live_optional_value_matches() {
  local label="$1"
  local expected="$2"
  shift 2
  local observed

  if ! observed="$(doctor_kubectl_jsonpath "$@")"; then
    doctor_juicefs_contract_error="live JuiceFS ${label} could not be read"
    return 1
  fi
  if [[ -n "${observed}" && "${observed}" != "${expected}" ]]; then
    doctor_juicefs_contract_error="live JuiceFS ${label} does not match substrate contract"
    return 1
  fi
  return 0
}

doctor_live_secret_data_matches() {
  local key="$1"
  local expected_value="$2"
  local expected_b64
  expected_b64="$(doctor_base64 "${expected_value}")"
  doctor_live_value_matches \
    "Secret data.${key}" \
    "${expected_b64}" \
    -n "${namespace}" get secret "${juicefs_secret_name}" -o "jsonpath={.data['${key}']}"
}

doctor_live_juicefs_contract_matches() {
  doctor_juicefs_contract_error=""

  doctor_live_named_value_matches \
    "StorageClass provisioner" \
    "JUICEFS_CSI_DRIVER" \
    "${juicefs_csi_driver}" \
    get storageclass "${juicefs_storage_class}" -o "jsonpath={.provisioner}" \
    || return 1

  doctor_live_optional_value_matches \
    "StorageClass provisioner secret name" \
    "${juicefs_secret_name}" \
    get storageclass "${juicefs_storage_class}" -o 'jsonpath={.parameters.csi\.storage\.k8s\.io/provisioner-secret-name}' \
    || return 1
  doctor_live_optional_value_matches \
    "StorageClass provisioner secret namespace" \
    "${namespace}" \
    get storageclass "${juicefs_storage_class}" -o 'jsonpath={.parameters.csi\.storage\.k8s\.io/provisioner-secret-namespace}' \
    || return 1
  doctor_live_optional_value_matches \
    "StorageClass node-publish secret name" \
    "${juicefs_secret_name}" \
    get storageclass "${juicefs_storage_class}" -o 'jsonpath={.parameters.csi\.storage\.k8s\.io/node-publish-secret-name}' \
    || return 1
  doctor_live_optional_value_matches \
    "StorageClass node-publish secret namespace" \
    "${namespace}" \
    get storageclass "${juicefs_storage_class}" -o 'jsonpath={.parameters.csi\.storage\.k8s\.io/node-publish-secret-namespace}' \
    || return 1

  doctor_live_secret_data_matches "name" "$(env_value_or_empty "${env_file}" JUICEFS_VOLUME_NAME)" || return 1
  doctor_live_secret_data_matches "metaurl" "${juicefs_meta}" || return 1
  doctor_live_secret_data_matches "storage" "s3" || return 1
  doctor_live_secret_data_matches "bucket" "$(env_value_or_empty "${env_file}" JUICEFS_BUCKET)" || return 1
  doctor_live_secret_data_matches "access-key" "${s3_access}" || return 1
  doctor_live_secret_data_matches "secret-key" "${s3_secret}" || return 1

  doctor_live_named_value_matches \
    "PVC storageClassName" \
    "JUICEFS_STORAGE_CLASS" \
    "${juicefs_storage_class}" \
    -n "${namespace}" get pvc "${juicefs_pvc_name}" -o "jsonpath={.spec.storageClassName}" \
    || return 1

  local access_modes
  if ! access_modes="$(doctor_kubectl_jsonpath -n "${namespace}" get pvc "${juicefs_pvc_name}" -o "jsonpath={.spec.accessModes[*]}")" \
    || [[ -z "${access_modes}" ]]; then
    doctor_juicefs_contract_error="live JuiceFS PVC accessModes could not be read"
    return 1
  fi
  case " ${access_modes} " in
    *" ReadWriteMany "*) ;;
    *)
      doctor_juicefs_contract_error="live JuiceFS PVC accessModes do not include ReadWriteMany"
      return 1
      ;;
  esac

  return 0
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
    add_check "k8s" "failed" "configured KUBECONFIG_PATH is not readable"
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
  "app database did not accept a simple query"

doctor_check_postgres_url \
  "postgres-juicefs-meta" \
  "JUICEFS_META_URL" \
  "${juicefs_meta}" \
  "JuiceFS metadata database accepted a simple query" \
  "JuiceFS metadata database did not accept a simple query"

if [[ -n "${s3_endpoint}" && -n "${s3_region}" && -n "${s3_bucket}" && -n "${s3_force_path_style}" && -n "${s3_access}" && -n "${s3_secret}" ]]; then
  if [[ "${dry_run}" == "true" ]]; then
    add_check "s3" "passed" "dry-run static: S3 endpoint, region, bucket, path-style, and key presence are valid; skipped read/write/delete probe" "substrate-csi-secret"
  elif [[ "${kubeconfig_unreadable}" == "true" ]]; then
    add_check "s3" "partial" "configured KUBECONFIG_PATH is not readable; live S3 read/write/delete probe was not verified" "substrate-csi-secret"
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

if [[ "${juicefs_meta}" =~ ^postgres:// ]]; then
  if juicefs_output="$("${ROOT_DIR}/scripts/validate-juicefs-contract.sh" --env "${env_file}" --secrets "${secrets_file}" 2>&1)"; then
    printf '%s\n' "${juicefs_output}"
    if [[ "${dry_run}" == "true" ]]; then
      add_check "juicefs-csi" "passed" "dry-run static: rendered JuiceFS Secret, StorageClass, and PVC contract is valid" "substrate-csi-secret"
      add_check "rwx-check" "passed" "dry-run static: PVC contract requests ReadWriteMany; skipped two-Job RWX write/read check"
    elif [[ "${kubeconfig_unreadable}" == "true" ]]; then
      add_check "juicefs-csi" "partial" "configured KUBECONFIG_PATH is not readable; live JuiceFS Secret, StorageClass, and PVC were not verified" "substrate-csi-secret"
      add_check "rwx-check" "partial" "live two-Job ReadWriteMany write/read check requires a readable configured KUBECONFIG_PATH; RWX was not verified"
    elif [[ "${kubectl_available}" != "true" ]]; then
      add_check "juicefs-csi" "partial" "kubectl not found; live JuiceFS Secret, StorageClass, and PVC were not verified" "substrate-csi-secret"
      add_check "rwx-check" "partial" "live two-Job ReadWriteMany write/read check requires kubectl; RWX was not verified"
    elif [[ "${cluster_reachable}" != "true" ]]; then
      add_check "juicefs-csi" "partial" "cluster namespace is not reachable; live JuiceFS resources were not verified" "substrate-csi-secret"
      add_check "rwx-check" "partial" "live two-Job ReadWriteMany write/read check requires a reachable namespace; RWX was not verified"
    elif ! "${kubectl_cmd[@]}" "${kubectl_args[@]}" get csidriver "${juicefs_csi_driver}" >/dev/null 2>&1; then
      add_check "juicefs-csi" "failed" "live JuiceFS CSIDriver ${juicefs_csi_driver} is missing" "substrate-csi-secret"
      add_check "rwx-check" "failed" "RWX was not verified because live JuiceFS CSIDriver ${juicefs_csi_driver} is missing"
    elif "${kubectl_cmd[@]}" "${kubectl_args[@]}" get storageclass "${juicefs_storage_class}" >/dev/null 2>&1 \
      && "${kubectl_cmd[@]}" "${kubectl_args[@]}" -n "${namespace}" get secret "${juicefs_secret_name}" >/dev/null 2>&1 \
      && "${kubectl_cmd[@]}" "${kubectl_args[@]}" -n "${namespace}" get pvc "${juicefs_pvc_name}" >/dev/null 2>&1; then
      if doctor_live_juicefs_contract_matches; then
        pvc_phase=""
        if pvc_phase="$("${kubectl_cmd[@]}" "${kubectl_args[@]}" -n "${namespace}" get pvc "${juicefs_pvc_name}" -o jsonpath={.status.phase} 2>/dev/null)" \
          && [[ -n "${pvc_phase}" ]]; then
          case "${pvc_phase}" in
            Bound)
              add_check "juicefs-csi" "passed" "live JuiceFS PVC phase is Bound and StorageClass, Secret, and PVC contract matches" "substrate-csi-secret"
              if doctor_resolve_rwx_check_image; then
                if rwx_output="$(rwx_write_read_check_run "${namespace}" "${juicefs_pvc_name}" "${resolved_rwx_check_image}" "${kubectl_cmd[0]}" "${kubectl_args[@]}" 2>&1)"; then
                  printf '%s\n' "${rwx_output}"
                  add_check "rwx-check" "passed" "live two-Job ReadWriteMany write/read check passed against PVC ${juicefs_pvc_name}"
                else
                  printf '%s\n' "${rwx_output}" >&2
                  add_check "rwx-check" "failed" "live two-Job ReadWriteMany write/read check failed; see doctor output for sanitized Job logs"
                fi
              else
                add_check "rwx-check" "failed" "${doctor_rwx_check_image_error}"
              fi
              ;;
            Pending|Lost)
              add_check "juicefs-csi" "failed" "live JuiceFS PVC phase is ${pvc_phase}, expected Bound" "substrate-csi-secret"
              add_check "rwx-check" "failed" "RWX was not verified because live JuiceFS PVC phase is ${pvc_phase}, expected Bound"
              ;;
            *)
              add_check "juicefs-csi" "failed" "live JuiceFS PVC phase is not Bound" "substrate-csi-secret"
              add_check "rwx-check" "failed" "RWX was not verified because live JuiceFS PVC phase is not Bound"
              ;;
          esac
        else
          add_check "juicefs-csi" "failed" "live JuiceFS PVC phase could not be read" "substrate-csi-secret"
          add_check "rwx-check" "failed" "RWX was not verified because live JuiceFS PVC phase could not be read"
        fi
      else
        add_check "juicefs-csi" "failed" "${doctor_juicefs_contract_error}" "substrate-csi-secret"
        add_check "rwx-check" "failed" "RWX was not verified because live JuiceFS contract did not match"
      fi
    else
      add_check "juicefs-csi" "failed" "live JuiceFS StorageClass, Secret, or PVC is missing" "substrate-csi-secret"
      add_check "rwx-check" "failed" "RWX was not verified because live JuiceFS StorageClass, Secret, or PVC is missing"
    fi
  else
    printf '%s\n' "${juicefs_output}" >&2
    add_check "juicefs-csi" "failed" "rendered JuiceFS CSI static contract is invalid" "substrate-csi-secret"
    add_check "rwx-check" "failed" "RWX cannot be checked without a valid JuiceFS PVC contract"
  fi
else
  add_check "juicefs-csi" "failed" "JUICEFS_META_URL shape is invalid" "substrate-csi-secret"
  add_check "rwx-check" "failed" "RWX cannot be checked without complete JuiceFS config"
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

overall="passed"
if [[ "${failed}" == "true" ]]; then
  overall="failed"
elif [[ "${partial}" == "true" ]]; then
  overall="partial"
fi

case "${overall}" in
  passed)
    info "doctor passed"
    exit 0
    ;;
  partial)
    warn "doctor partial"
    exit 2
    ;;
  failed)
    warn "doctor failed"
    exit 1
    ;;
esac
