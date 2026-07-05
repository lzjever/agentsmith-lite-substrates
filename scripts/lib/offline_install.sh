#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_INSTALL_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"
# shellcheck source=offline.sh
source "${SCRIPT_LIB_DIR}/offline.sh"
# shellcheck source=juicefs.sh
source "${SCRIPT_LIB_DIR}/juicefs.sh"
# shellcheck source=minio.sh
source "${SCRIPT_LIB_DIR}/minio.sh"
# shellcheck source=postgres.sh
source "${SCRIPT_LIB_DIR}/postgres.sh"

offline_install_kubectl() {
  local cache_dir="$1"
  local env_file="$2"
  shift 2
  local kubectl_bin kubeconfig_path kube_context
  local kubectl_args=()
  kubectl_bin="$(cache_relative_path "${cache_dir}" "bin/kubectl" "kubectl binary")"
  kubeconfig_path="$(env_value_or_empty "${env_file}" KUBECONFIG_PATH)"
  kube_context="$(env_value_or_empty "${env_file}" KUBE_CONTEXT)"
  [[ -n "${kubeconfig_path}" ]] && kubectl_args+=(--kubeconfig "${kubeconfig_path}")
  [[ -n "${kube_context}" ]] && kubectl_args+=(--context "${kube_context}")
  "${kubectl_bin}" "${kubectl_args[@]}" "$@"
}

offline_install_run_k3s_installer() {
  local cache_dir="$1"
  local env_file="$2"
  local output_dir="$3"
  local install_script k3s_bin airgap_images bin_dir airgap_dir kubeconfig_path install_exec kubeconfig_hint
  install_script="$(cache_relative_path "${cache_dir}" "scripts/install-k3s.sh" "k3s install script")"
  k3s_bin="$(cache_relative_path "${cache_dir}" "bin/k3s" "k3s binary")"
  airgap_images="$(cache_relative_path "${cache_dir}" "images/k3s/k3s-airgap-images-amd64.tar.zst" "k3s airgap images")"
  bin_dir="$(dirname "${k3s_bin}")"
  airgap_dir="${K3S_AIRGAP_DIR:-/var/lib/rancher/k3s/agent/images}"
  kubeconfig_path="$(env_value_or_empty "${env_file}" KUBECONFIG_PATH)"
  kubeconfig_hint="${output_dir}/kubeconfig"
  [[ -n "${kubeconfig_path}" ]] || die "KUBECONFIG_PATH must be set for p1-real offline install; configure kubernetes.kubeconfigOutput so ${kubeconfig_hint} is written"
  install_exec="${INSTALL_K3S_EXEC:-server --write-kubeconfig ${kubeconfig_path} --write-kubeconfig-mode 600}"

  mkdir -p "${airgap_dir}"
  mkdir -p "$(dirname "${kubeconfig_path}")"
  cp -- "${airgap_images}" "${airgap_dir}/$(basename "${airgap_images}")"

  info "install-offline: running cached k3s installer"
  INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_SKIP_SELINUX_RPM=true \
    INSTALL_K3S_BIN_DIR="${bin_dir}" \
    INSTALL_K3S_BIN_DIR_READ_ONLY=true \
    K3S_BINARY_PATH="${k3s_bin}" \
    INSTALL_K3S_EXEC="${install_exec}" \
    "${install_script}"
}

offline_install_render_workload_manifest() {
  local input="$1"
  local output="$2"
  local namespace="$3"
  local image_ref="$4"

  awk -v ns="${namespace}" -v image_ref="${image_ref}" '
    /^[[:space:]]*namespace:[[:space:]]*agentsmith[[:space:]]*$/ {
      sub(/agentsmith[[:space:]]*$/, ns)
      print
      next
    }
    /^[[:space:]]*image:[[:space:]]*/ {
      match($0, /^[[:space:]]*/)
      print substr($0, RSTART, RLENGTH) "image: " image_ref
      next
    }
    { print }
  ' "${input}" >"${output}"
}

offline_install_render_manifests() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local render_dir="$4"
  local lock_file namespace postgres_image minio_image minio_client_image juicefs_csi_image

  mkdir -p "${render_dir}"
  render_juicefs_contract "${env_file}" "${secrets_file}" "${OFFLINE_INSTALL_ROOT}/manifests/juicefs-csi" "${render_dir}"

  lock_file="$(cache_relative_path "${cache_dir}" "images/images.lock" "images lock file")"
  postgres_image="$(images_lock_image_ref "${lock_file}" "postgres")" \
    || die "p1-real images.lock is missing dependency image entry: postgres"
  minio_image="$(images_lock_image_ref "${lock_file}" "minio")" \
    || die "p1-real images.lock is missing dependency image entry: minio"
  minio_client_image="$(images_lock_image_ref "${lock_file}" "minio-client")" \
    || die "p1-real images.lock is missing dependency image entry: minio-client"
  juicefs_csi_image="$(images_lock_image_ref "${lock_file}" "juicefs-csi")" \
    || die "p1-real images.lock is missing dependency image entry: juicefs-csi"
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"

  render_postgres_secret_manifest "${env_file}" "${secrets_file}" "${render_dir}/postgres-secret.yaml"
  render_minio_secret_manifest "${env_file}" "${secrets_file}" "${OFFLINE_INSTALL_ROOT}/manifests/minio" "${render_dir}/minio-secret.yaml"
  offline_install_render_workload_manifest "${OFFLINE_INSTALL_ROOT}/manifests/postgres/postgres.yaml" "${render_dir}/postgres.yaml" "${namespace}" "${postgres_image}"
  offline_install_render_workload_manifest "${OFFLINE_INSTALL_ROOT}/manifests/minio/minio.yaml" "${render_dir}/minio.yaml" "${namespace}" "${minio_image}"
  render_minio_bucket_init_job "${env_file}" "${OFFLINE_INSTALL_ROOT}/manifests/minio" "${render_dir}/minio-bucket-init-job.yaml" "${minio_client_image}"
  render_juicefs_format_job "${env_file}" "${secrets_file}" "${OFFLINE_INSTALL_ROOT}/manifests/juicefs-csi" "${render_dir}/juicefs-format-job.yaml" "${juicefs_csi_image}"
}

offline_install_import_images() {
  local cache_dir="$1"
  local import_script
  import_script="$(cache_relative_path "${cache_dir}" "scripts/import-images.sh" "image import script")"
  info "install-offline: importing cached OCI archives"
  "${import_script}"
}

offline_install_run_doctor() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local output_dir="$4"
  local kubectl_bin report_file status
  kubectl_bin="$(cache_relative_path "${cache_dir}" "bin/kubectl" "kubectl binary")"
  report_file="${output_dir}/doctor-report.json"

  set +e
  KUBECTL_BIN="${kubectl_bin}" \
    PATH="$(dirname "${kubectl_bin}"):${PATH}" \
    "${OFFLINE_INSTALL_ROOT}/scripts/doctor.sh" \
    --env "${env_file}" \
    --secrets "${secrets_file}" \
    --offline-cache "${cache_dir}" \
    --report "${report_file}"
  status=$?
  set -e

  case "${status}" in
    0)
      info "install-offline: doctor passed"
      ;;
    2)
      warn "install-offline: doctor reported partial; live S3/RWX and remaining smoke checks are still incomplete"
      ;;
    *)
      die "doctor failed after offline install; see ${report_file}"
      ;;
  esac
}

offline_install_wait_postgres_ready() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  info "install-offline: waiting for PostgreSQL StatefulSet readiness"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" rollout status statefulset/postgres --timeout=180s
}

offline_install_wait_minio_ready() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  info "install-offline: waiting for MinIO StatefulSet readiness"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" rollout status statefulset/minio --timeout=180s
}

offline_install_init_minio_bucket() {
  local cache_dir="$1"
  local env_file="$2"
  local render_dir="$3"
  local namespace bucket
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  bucket="$(env_value_or_empty "${env_file}" S3_BUCKET)"
  minio_validate_bucket_name "${bucket}"
  info "install-offline: initializing MinIO bucket"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/minio-bucket-init-job.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" wait --for=condition=complete job/agentsmith-lite-minio-bucket-init --timeout=120s
  offline_install_kubectl "${cache_dir}" "${env_file}" delete -f "${render_dir}/minio-bucket-init-job.yaml" --ignore-not-found=true
}

offline_install_format_juicefs() {
  local cache_dir="$1"
  local env_file="$2"
  local render_dir="$3"
  local namespace logs status
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"

  info "install-offline: formatting JuiceFS volume"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/juicefs-secret.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/juicefs-format-job.yaml"

  set +e
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" wait --for=condition=complete job/agentsmith-lite-juicefs-format --timeout=120s
  status=$?
  logs="$(offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" logs job/agentsmith-lite-juicefs-format 2>&1)"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" delete -f "${render_dir}/juicefs-format-job.yaml" --ignore-not-found=true
  set -e

  if grep -Fq "agentsmith-lite-juicefs-format: existing JuiceFS volume mismatch" <<<"${logs}"; then
    die "existing JuiceFS volume mismatch; refusing to apply JuiceFS PVC contract"
  fi
  if [[ "${status}" -ne 0 ]]; then
    die "JuiceFS format Job failed; refusing to apply JuiceFS PVC contract"
  fi
  if ! grep -Fq "agentsmith-lite-juicefs-format: ok" <<<"${logs}"; then
    die "JuiceFS format Job did not report a successful idempotent format"
  fi
}

offline_install_init_postgres_databases() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local namespace sql
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  postgres_validate_self_hosted_urls "${env_file}" "${secrets_file}"
  sql="$(postgres_init_sql_from_env "${env_file}" "${secrets_file}")"
  info "install-offline: initializing PostgreSQL app and JuiceFS metadata databases"
  printf '%s\n' "${sql}" \
    | offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" exec -i statefulset/postgres -- sh -c 'psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres'
  offline_install_verify_postgres_database "${cache_dir}" "${env_file}" "${namespace}" "POSTGRES_PASSWORD" "${postgres_app_HOST}" "${postgres_app_PORT}" "${postgres_app_USER}" "${postgres_app_DATABASE}"
  offline_install_verify_postgres_database "${cache_dir}" "${env_file}" "${namespace}" "JUICEFS_META_PASSWORD" "${postgres_meta_HOST}" "${postgres_meta_PORT}" "${postgres_meta_USER}" "${postgres_meta_DATABASE}"
}

offline_install_verify_postgres_database() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace="$3"
  local password_env="$4"
  local host="$5"
  local port="$6"
  local user="$7"
  local database="$8"

  info "install-offline: verifying PostgreSQL database ${database} as ${user}"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" exec -i statefulset/postgres -- sh -c 'case "$1" in POSTGRES_PASSWORD) PGPASSWORD="${POSTGRES_PASSWORD:-}" ;; JUICEFS_META_PASSWORD) PGPASSWORD="${JUICEFS_META_PASSWORD:-}" ;; *) exit 64 ;; esac; export PGPASSWORD; test -n "${PGPASSWORD}" || exit 65; psql -v ON_ERROR_STOP=1 -h "$2" -p "$3" -U "$4" -d "$5" -Atc "select 1"' sh "${password_env}" "${host}" "${port}" "${user}" "${database}" < /dev/null
}

run_p1_real_existing_cloud_validation() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local output_dir="$4"

  info "install-offline: existing-cloud mode; skipping self-hosted PostgreSQL, MinIO, and k3s mutation"
  offline_install_run_doctor "${cache_dir}" "${env_file}" "${secrets_file}" "${output_dir}"
}

run_p1_real_offline_install() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local output_dir="$4"
  local render_dir namespace_manifest

  render_dir="${output_dir}/rendered/offline-install"
  namespace_manifest="$(cache_relative_path "${cache_dir}" "manifests/namespace-bootstrap/namespace.yaml" "namespace bootstrap manifest")"

  postgres_validate_self_hosted_urls "${env_file}" "${secrets_file}"
  minio_validate_self_hosted_env "${env_file}" "${secrets_file}"
  offline_install_run_k3s_installer "${cache_dir}" "${env_file}" "${output_dir}"
  offline_install_import_images "${cache_dir}"

  info "install-offline: applying cached namespace bootstrap"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${namespace_manifest}"

  offline_install_render_manifests "${cache_dir}" "${env_file}" "${secrets_file}" "${render_dir}"

  info "install-offline: applying rendered Postgres manifests"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/postgres-secret.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/postgres.yaml"
  offline_install_wait_postgres_ready "${cache_dir}" "${env_file}"
  offline_install_init_postgres_databases "${cache_dir}" "${env_file}" "${secrets_file}"
  info "install-offline: applying rendered MinIO manifests"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/minio-secret.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/minio.yaml"
  offline_install_wait_minio_ready "${cache_dir}" "${env_file}"
  offline_install_init_minio_bucket "${cache_dir}" "${env_file}" "${render_dir}"

  offline_install_format_juicefs "${cache_dir}" "${env_file}" "${render_dir}"
  info "install-offline: applying rendered JuiceFS CSI contract"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/juicefs-storageclass-pvc.yaml"

  offline_install_run_doctor "${cache_dir}" "${env_file}" "${secrets_file}" "${output_dir}"
}
