#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_INSTALL_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"
# shellcheck source=offline.sh
source "${SCRIPT_LIB_DIR}/offline.sh"
# shellcheck source=juicefs.sh
source "${SCRIPT_LIB_DIR}/juicefs.sh"

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
  local lock_file namespace postgres_image minio_image

  mkdir -p "${render_dir}"
  render_juicefs_contract "${env_file}" "${secrets_file}" "${OFFLINE_INSTALL_ROOT}/manifests/juicefs-csi" "${render_dir}"

  lock_file="$(cache_relative_path "${cache_dir}" "images/images.lock" "images lock file")"
  postgres_image="$(images_lock_image_ref "${lock_file}" "postgres")" \
    || die "p1-real images.lock is missing dependency image entry: postgres"
  minio_image="$(images_lock_image_ref "${lock_file}" "minio")" \
    || die "p1-real images.lock is missing dependency image entry: minio"
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"

  offline_install_render_workload_manifest "${OFFLINE_INSTALL_ROOT}/manifests/postgres/postgres.yaml" "${render_dir}/postgres.yaml" "${namespace}" "${postgres_image}"
  offline_install_render_workload_manifest "${OFFLINE_INSTALL_ROOT}/manifests/minio/minio.yaml" "${render_dir}/minio.yaml" "${namespace}" "${minio_image}"
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

run_p1_real_offline_install() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local output_dir="$4"
  local render_dir namespace_manifest

  render_dir="${output_dir}/rendered/offline-install"
  namespace_manifest="$(cache_relative_path "${cache_dir}" "manifests/namespace-bootstrap/namespace.yaml" "namespace bootstrap manifest")"

  offline_install_run_k3s_installer "${cache_dir}" "${env_file}" "${output_dir}"
  offline_install_import_images "${cache_dir}"

  info "install-offline: applying cached namespace bootstrap"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${namespace_manifest}"

  offline_install_render_manifests "${cache_dir}" "${env_file}" "${secrets_file}" "${render_dir}"
  info "install-offline: applying rendered JuiceFS CSI contract"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/juicefs-secret.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/juicefs-storageclass-pvc.yaml"

  info "install-offline: applying rendered Postgres and MinIO manifests"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/postgres.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/minio.yaml"

  offline_install_run_doctor "${cache_dir}" "${env_file}" "${secrets_file}" "${output_dir}"
}
