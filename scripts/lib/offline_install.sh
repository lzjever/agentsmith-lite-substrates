#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_INSTALL_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"
# shellcheck source=offline.sh
source "${SCRIPT_LIB_DIR}/offline.sh"
# shellcheck source=juicefs.sh
source "${SCRIPT_LIB_DIR}/juicefs.sh"
# shellcheck source=rwx_write_read_check.sh
source "${SCRIPT_LIB_DIR}/rwx_write_read_check.sh"
# shellcheck source=minio.sh
source "${SCRIPT_LIB_DIR}/minio.sh"
# shellcheck source=postgres.sh
source "${SCRIPT_LIB_DIR}/postgres.sh"
# shellcheck source=keycloak.sh
source "${SCRIPT_LIB_DIR}/keycloak.sh"
# shellcheck source=local_openai.sh
source "${SCRIPT_LIB_DIR}/local_openai.sh"
# shellcheck source=local_ingress_tls.sh
source "${SCRIPT_LIB_DIR}/local_ingress_tls.sh"
# shellcheck source=k3s_host_firewall.sh
source "${SCRIPT_LIB_DIR}/k3s_host_firewall.sh"

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

offline_install_delete_job_best_effort() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace="$3"
  local job_name="$4"

  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" delete job "${job_name}" --ignore-not-found=true || true
}

offline_install_describe_job_failure_best_effort() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace="$3"
  local job_name="$4"

  printf 'install-offline: collecting %s logs\n' "${job_name}" >&2
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" logs -l "job-name=${job_name}" --all-containers --tail=-1 >&2 || true
  printf 'install-offline: describing %s\n' "${job_name}" >&2
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" describe job "${job_name}" >&2 || true
}

offline_install_run_once_job() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace="$3"
  local job_name="$4"
  local manifest="$5"
  local timeout="$6"
  local apply_failure="$7"
  local wait_failure="$8"
  local apply_status wait_status

  offline_install_delete_job_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"

  set +e
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${manifest}"
  apply_status=$?
  set -e
  if [[ "${apply_status}" -ne 0 ]]; then
    offline_install_describe_job_failure_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"
    die "${apply_failure}"
  fi

  set +e
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" wait --for=condition=complete "job/${job_name}" --timeout="${timeout}"
  wait_status=$?
  set -e
  if [[ "${wait_status}" -ne 0 ]]; then
    offline_install_describe_job_failure_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"
    die "${wait_failure}"
  fi

  offline_install_delete_job_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"
}

offline_install_helm() {
  local cache_dir="$1"
  local env_file="$2"
  shift 2
  local helm_bin kubeconfig_path kube_context
  local helm_args=()
  helm_bin="$(cache_relative_path "${cache_dir}" "bin/helm" "helm binary")"
  kubeconfig_path="$(env_value_or_empty "${env_file}" KUBECONFIG_PATH)"
  kube_context="$(env_value_or_empty "${env_file}" KUBE_CONTEXT)"
  [[ -n "${kubeconfig_path}" ]] && helm_args+=(--kubeconfig "${kubeconfig_path}")
  [[ -n "${kube_context}" ]] && helm_args+=(--kube-context "${kube_context}")
  "${helm_bin}" "${helm_args[@]}" "$@"
}

offline_install_run_k3s_installer() {
  local cache_dir="$1"
  local env_file="$2"
  local output_dir="$3"
  local install_script cached_k3s_bin airgap_images cache_root stable_bin_dir stable_bin_root stable_k3s_bin staged_k3s_bin airgap_dir kubeconfig_path install_exec
  install_script="$(cache_relative_path "${cache_dir}" "scripts/install-k3s.sh" "k3s install script")"
  cached_k3s_bin="$(cache_relative_path "${cache_dir}" "bin/k3s" "k3s binary")"
  airgap_images="$(cache_relative_path "${cache_dir}" "images/k3s/k3s-airgap-images-amd64.tar.zst" "k3s airgap images")"
  stable_bin_dir="${K3S_STABLE_BIN_DIR:-/usr/local/bin}"
  [[ "${stable_bin_dir}" == /* ]] || die "K3S_STABLE_BIN_DIR must be an absolute path"
  stable_k3s_bin="${stable_bin_dir}/k3s"
  airgap_dir="${K3S_AIRGAP_DIR:-/var/lib/rancher/k3s/agent/images}"
  kubeconfig_path="$(env_value_or_empty "${env_file}" KUBECONFIG_PATH)"
  [[ -n "${kubeconfig_path}" ]] || die "KUBECONFIG_PATH must be set for p1-real offline install; configure kubernetes.kubeconfigOutput or kubernetes.kubeconfigPath"
  install_exec="${INSTALL_K3S_EXEC:-server --write-kubeconfig ${kubeconfig_path} --write-kubeconfig-mode 600}"

  k3s_host_firewall_prepare
  install -d -m 0755 "${stable_bin_dir}"
  cache_root="$(cd "${cache_dir}" && pwd -P)"
  stable_bin_root="$(cd "${stable_bin_dir}" && pwd -P)"
  case "${stable_bin_root}" in
    "${cache_root}"|"${cache_root}/"*) die "K3S_STABLE_BIN_DIR must not be inside the offline cache" ;;
  esac
  staged_k3s_bin="$(mktemp "${stable_bin_dir}/.k3s.XXXXXX")"
  install -m 0755 "${cached_k3s_bin}" "${staged_k3s_bin}"
  mv -f -- "${staged_k3s_bin}" "${stable_k3s_bin}"
  mkdir -p "${airgap_dir}"
  mkdir -p "$(dirname "${kubeconfig_path}")"
  cp -- "${airgap_images}" "${airgap_dir}/$(basename "${airgap_images}")"

  info "install-offline: running cached k3s installer"
  INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_SKIP_SELINUX_RPM=true \
    INSTALL_K3S_BIN_DIR="${stable_bin_dir}" \
    INSTALL_K3S_BIN_DIR_READ_ONLY=true \
    INSTALL_K3S_EXEC="${install_exec}" \
    "${install_script}"
}

offline_install_delete_coredns_service_lookup_pod() {
  local cache_dir="$1"
  local env_file="$2"

  offline_install_kubectl "${cache_dir}" "${env_file}" -n kube-system --request-timeout=20s delete pod \
    -l "app.kubernetes.io/managed-by=agentsmith-lite-substrate-probe,agentsmith-lite/check=coredns-service-lookup" \
    --field-selector "metadata.name=agentsmith-lite-coredns-lookup" \
    --ignore-not-found=true \
    --wait=false >/dev/null 2>&1 || true
}

offline_install_run_coredns_service_lookup() (
  local cache_dir="$1"
  local env_file="$2"
  local lock_file image_ref pod_name manifest tmp_dir status

  lock_file="$(cache_relative_path "${cache_dir}" "images/images.lock" "images lock file")"
  image_ref="$(images_lock_image_ref "${lock_file}" "rwx-check")" \
    || die "p1-real images.lock is missing dependency image entry: rwx-check"
  require_digest_pinned_image_ref "images.lock entry rwx-check" "${image_ref}"
  pod_name="agentsmith-lite-coredns-lookup"
  tmp_dir="$(mktemp -d)"
  manifest="${tmp_dir}/coredns-lookup-pod.yaml"
  cleanup() {
    offline_install_delete_coredns_service_lookup_pod "${cache_dir}" "${env_file}"
    rm -rf "${tmp_dir}"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  offline_install_delete_coredns_service_lookup_pod "${cache_dir}" "${env_file}"
  cat >"${manifest}" <<EOF_POD
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: agentsmith-lite-substrate-probe
    agentsmith-lite/check: coredns-service-lookup
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 120
  terminationGracePeriodSeconds: 0
  containers:
    - name: lookup
      image: ${image_ref}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "sleep 180"]
EOF_POD

  info "install-offline: checking CoreDNS service lookup"
  status=0
  if ! offline_install_kubectl "${cache_dir}" "${env_file}" --request-timeout=20s apply -f "${manifest}"; then
    status=1
  elif ! offline_install_kubectl "${cache_dir}" "${env_file}" -n kube-system --request-timeout=20s wait --for=condition=Ready "pod/${pod_name}" --timeout=90s; then
    status=1
  elif ! offline_install_kubectl "${cache_dir}" "${env_file}" -n kube-system --request-timeout=20s exec "${pod_name}" -- nslookup kubernetes.default.svc.cluster.local; then
    status=1
  fi
  if [[ "${status}" -ne 0 ]]; then
    offline_install_kubectl "${cache_dir}" "${env_file}" -n kube-system --request-timeout=20s logs "${pod_name}" >&2 || true
    die "CoreDNS service lookup failed after k3s start; refusing to create workload manifests"
  fi
)

offline_install_render_juicefs_csi_helm_values() {
  local env_file="$1"
  local lock_file="$2"
  local output="$3"
  local driver_name
  local juicefs_csi_image liveness_image registrar_image provisioner_image resizer_image
  local driver_record liveness_record registrar_record provisioner_record resizer_record
  local driver_repo driver_tag liveness_repo liveness_tag registrar_repo registrar_tag
  local provisioner_repo provisioner_tag resizer_repo resizer_tag

  driver_name="$(env_value_or_empty "${env_file}" JUICEFS_CSI_DRIVER)"
  [[ -n "${driver_name}" ]] || die "JUICEFS_CSI_DRIVER must be set before rendering JuiceFS CSI Helm values"

  juicefs_csi_image="$(images_lock_image_ref "${lock_file}" "juicefs-csi")" \
    || die "p1-real images.lock is missing dependency image entry: juicefs-csi"
  liveness_image="$(images_lock_image_ref "${lock_file}" "juicefs-csi-liveness-probe")" \
    || die "p1-real images.lock is missing dependency image entry: juicefs-csi-liveness-probe"
  registrar_image="$(images_lock_image_ref "${lock_file}" "juicefs-csi-node-driver-registrar")" \
    || die "p1-real images.lock is missing dependency image entry: juicefs-csi-node-driver-registrar"
  provisioner_image="$(images_lock_image_ref "${lock_file}" "juicefs-csi-provisioner")" \
    || die "p1-real images.lock is missing dependency image entry: juicefs-csi-provisioner"
  resizer_image="$(images_lock_image_ref "${lock_file}" "juicefs-csi-resizer")" \
    || die "p1-real images.lock is missing dependency image entry: juicefs-csi-resizer"

  driver_record="$(helm_image_repository_tag "images.lock entry juicefs-csi" "${juicefs_csi_image}")"
  liveness_record="$(helm_image_repository_tag "images.lock entry juicefs-csi-liveness-probe" "${liveness_image}")"
  registrar_record="$(helm_image_repository_tag "images.lock entry juicefs-csi-node-driver-registrar" "${registrar_image}")"
  provisioner_record="$(helm_image_repository_tag "images.lock entry juicefs-csi-provisioner" "${provisioner_image}")"
  resizer_record="$(helm_image_repository_tag "images.lock entry juicefs-csi-resizer" "${resizer_image}")"

  IFS=$'\t' read -r driver_repo driver_tag <<<"${driver_record}"
  IFS=$'\t' read -r liveness_repo liveness_tag <<<"${liveness_record}"
  IFS=$'\t' read -r registrar_repo registrar_tag <<<"${registrar_record}"
  IFS=$'\t' read -r provisioner_repo provisioner_tag <<<"${provisioner_record}"
  IFS=$'\t' read -r resizer_repo resizer_tag <<<"${resizer_record}"

  cat >"${output}" <<EOF_VALUES
driverName: ${driver_name}
image:
  repository: ${driver_repo}
  tag: "${driver_tag}"
  pullPolicy: IfNotPresent
sidecars:
  livenessProbeImage:
    repository: ${liveness_repo}
    tag: "${liveness_tag}"
    pullPolicy: IfNotPresent
  nodeDriverRegistrarImage:
    repository: ${registrar_repo}
    tag: "${registrar_tag}"
    pullPolicy: IfNotPresent
  csiProvisionerImage:
    repository: ${provisioner_repo}
    tag: "${provisioner_tag}"
    pullPolicy: IfNotPresent
  csiResizerImage:
    repository: ${resizer_repo}
    tag: "${resizer_tag}"
    pullPolicy: IfNotPresent
dashboard:
  enabled: false
snapshot:
  enabled: false
storageClasses:
  - name: agentsmith-lite-managed-outside-chart
    enabled: false
EOF_VALUES
}

offline_install_render_workload_manifest() {
  local input="$1"
  local output="$2"
  local namespace="$3"
  local image_ref="$4"

  local content
  content="$(<"${input}")"
  content="${content//\$\{SUBSTRATE_NAMESPACE\}/${namespace}}"
  content="$(awk -v image_ref="${image_ref}" '
    /^[[:space:]]*image:[[:space:]]*/ {
      match($0, /^[[:space:]]*/)
      print substr($0, RSTART, RLENGTH) "image: " image_ref
      next
    }
    { print }
  ' <<<"${content}")"
  if grep -Eq '\$\{[A-Z0-9_]+\}' <<<"${content}"; then
    die "workload manifest template has unresolved placeholders after rendering: ${input}"
  fi
  printf '%s\n' "${content}" >"${output}"
}

offline_install_render_namespace_manifest() {
  local input="$1"
  local output="$2"
  local env_file="$3"
  local app_namespace substrate_namespace content

  app_namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  substrate_namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  [[ -n "${app_namespace}" ]] || die "KUBE_NAMESPACE must be set before rendering namespace bootstrap"
  [[ -n "${substrate_namespace}" ]] || die "SUBSTRATE_NAMESPACE must be set before rendering namespace bootstrap"
  need_file "${input}"
  mkdir -p "$(dirname "${output}")"
  content="$(<"${input}")"
  content="${content//\$\{KUBE_NAMESPACE\}/${app_namespace}}"
  content="${content//\$\{SUBSTRATE_NAMESPACE\}/${substrate_namespace}}"
  if grep -Eq '\$\{[A-Z0-9_]+\}' <<<"${content}"; then
    die "namespace bootstrap manifest has unresolved placeholders after rendering"
  fi
  printf '%s\n' "${content}" >"${output}"
}

offline_install_render_manifests() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local render_dir="$4"
  local lock_file substrate_namespace postgres_image minio_image minio_client_image juicefs_csi_image keycloak_image auth_mode local_openai_image
  local app_secrets_file
  local keycloak_user="" keycloak_password="" keycloak_database=""

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
  local_openai_image="$(images_lock_image_ref "${lock_file}" "local-openai-provider")" \
    || die "p1-real images.lock is missing dependency image entry: local-openai-provider"
  substrate_namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  auth_mode="$(env_value_or_empty "${env_file}" AUTH_MODE)"
  app_secrets_file="$(dirname "${secrets_file}")/app.secrets.env"
  if [[ "${auth_mode}" == "oidc" ]]; then
    keycloak_image="$(images_lock_image_ref "${lock_file}" "keycloak")" \
      || die "p1-real images.lock is missing dependency image entry: keycloak"
    keycloak_prepare_self_hosted_context "${env_file}" "${secrets_file}"
    keycloak_user="${keycloak_db_user}"
    keycloak_password="${keycloak_db_password}"
    keycloak_database="${keycloak_db_database}"
  fi

  render_postgres_secret_manifest "${env_file}" "${secrets_file}" "${render_dir}/postgres-secret.yaml" "${keycloak_user}" "${keycloak_password}" "${keycloak_database}"
  render_minio_secret_manifest "${env_file}" "${secrets_file}" "${OFFLINE_INSTALL_ROOT}/manifests/minio" "${render_dir}/minio-secret.yaml"
  offline_install_render_workload_manifest "${OFFLINE_INSTALL_ROOT}/manifests/postgres/postgres.yaml" "${render_dir}/postgres.yaml" "${substrate_namespace}" "${postgres_image}"
  render_postgres_init_job "${env_file}" "${secrets_file}" "${OFFLINE_INSTALL_ROOT}/manifests/postgres" "${render_dir}/postgres-init-job.yaml" "${postgres_image}" "${keycloak_user}" "${keycloak_password}" "${keycloak_database}"
  offline_install_render_workload_manifest "${OFFLINE_INSTALL_ROOT}/manifests/minio/minio.yaml" "${render_dir}/minio.yaml" "${substrate_namespace}" "${minio_image}"
  render_minio_bucket_init_job "${env_file}" "${OFFLINE_INSTALL_ROOT}/manifests/minio" "${render_dir}/minio-bucket-init-job.yaml" "${minio_client_image}"
  render_juicefs_format_job "${env_file}" "${secrets_file}" "${OFFLINE_INSTALL_ROOT}/manifests/juicefs-csi" "${render_dir}/juicefs-format-job.yaml" "${juicefs_csi_image}"
  offline_install_render_juicefs_csi_helm_values "${env_file}" "${lock_file}" "${render_dir}/juicefs-csi-values.yaml"
  render_local_openai_manifests "${env_file}" "${app_secrets_file}" "${OFFLINE_INSTALL_ROOT}/manifests/local-openai" "${render_dir}" "${local_openai_image}"
  if [[ "${auth_mode}" == "oidc" ]]; then
    local_ingress_tls_ensure \
      "$(dirname "${env_file}")/local-ingress-tls" \
      "$(env_value_or_empty "${env_file}" APP_PUBLIC_BASE_URL)" \
      "${keycloak_public_base_url}"
    render_local_ingress_tls_secret \
      "${render_dir}/app-ingress-tls-secret.yaml" \
      "$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)" \
      "$(env_value_or_empty "${env_file}" APP_TLS_SECRET_NAME)" \
      "$(dirname "${env_file}")/local-ingress-tls"
    render_local_ingress_tls_secret \
      "${render_dir}/keycloak-ingress-tls-secret.yaml" \
      "${substrate_namespace}" \
      "$(env_value_or_empty "${env_file}" APP_TLS_SECRET_NAME)" \
      "$(dirname "${env_file}")/local-ingress-tls"
    render_keycloak_secret_manifest "${render_dir}/keycloak-secret.yaml"
    render_keycloak_deployment_manifest "${OFFLINE_INSTALL_ROOT}/manifests/keycloak" "${render_dir}/keycloak.yaml" "${keycloak_image}"
    render_keycloak_bootstrap_job "${OFFLINE_INSTALL_ROOT}/manifests/keycloak" "${render_dir}/keycloak-bootstrap-job.yaml" "${keycloak_image}"
  fi
}

offline_install_render_self_hosted_dry_run_manifests() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local output_dir="$4"
  local render_dir="${output_dir}/rendered/offline-install"

  if [[ "$(offline_cache_mode "${cache_dir}")" != "p1-real" ]]; then
    return 0
  fi

  offline_install_render_manifests "${cache_dir}" "${env_file}" "${secrets_file}" "${render_dir}"
}

offline_install_import_images() {
  local cache_dir="$1"
  local import_script
  import_script="$(cache_relative_path "${cache_dir}" "scripts/import-images.sh" "image import script")"
  info "install-offline: importing cached OCI archives"
  "${import_script}"
}

offline_install_install_juicefs_csi_chart() {
  local cache_dir="$1"
  local env_file="$2"
  local render_dir="$3"
  local chart values
  chart="$(cache_relative_path "${cache_dir}" "charts/juicefs-csi.tgz" "JuiceFS CSI chart artifact")"
  values="${render_dir}/juicefs-csi-values.yaml"
  need_file "${values}"

  info "install-offline: installing JuiceFS CSI chart with cached Helm"
  offline_install_helm "${cache_dir}" "${env_file}" \
    upgrade --install juicefs-csi-driver "${chart}" \
    --namespace kube-system \
    --create-namespace \
    --wait \
    --timeout 180s \
    -f "${values}"
}

offline_install_wait_postgres_ready() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  info "install-offline: waiting for PostgreSQL StatefulSet readiness"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" rollout status statefulset/postgres --timeout=180s
}

offline_install_wait_minio_ready() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  info "install-offline: waiting for MinIO StatefulSet readiness"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" rollout status statefulset/minio --timeout=180s
}

offline_install_wait_juicefs_pvc_bound() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace pvc_name
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  pvc_name="$(env_value_or_empty "${env_file}" JUICEFS_PVC_NAME)"
  info "install-offline: waiting for JuiceFS PVC to bind"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" wait --for=jsonpath={.status.phase}=Bound "pvc/${pvc_name}" --timeout=180s
}

offline_install_check_juicefs_rwx_write_read() {
  local cache_dir="$1"
  local env_file="$2"
  local lock_file namespace pvc_name image_ref kubectl_bin kubeconfig_path kube_context
  local kubectl_args=()

  lock_file="$(cache_relative_path "${cache_dir}" "images/images.lock" "images lock file")"
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  pvc_name="$(env_value_or_empty "${env_file}" JUICEFS_PVC_NAME)"
  image_ref="$(images_lock_image_ref "${lock_file}" "rwx-check")" \
    || die "p1-real images.lock is missing dependency image entry: rwx-check"
  kubectl_bin="$(cache_relative_path "${cache_dir}" "bin/kubectl" "kubectl binary")"
  kubeconfig_path="$(env_value_or_empty "${env_file}" KUBECONFIG_PATH)"
  kube_context="$(env_value_or_empty "${env_file}" KUBE_CONTEXT)"

  [[ -n "${namespace}" ]] || die "KUBE_NAMESPACE must be set before running JuiceFS RWX write/read check"
  [[ -n "${pvc_name}" ]] || die "JUICEFS_PVC_NAME must be set before running JuiceFS RWX write/read check"
  [[ -x "${kubectl_bin}" ]] || die "kubectl binary is not executable for JuiceFS RWX write/read check"
  require_digest_pinned_image_ref "images.lock entry rwx-check" "${image_ref}"
  [[ -n "${kubeconfig_path}" ]] && kubectl_args+=(--kubeconfig "${kubeconfig_path}")
  [[ -n "${kube_context}" ]] && kubectl_args+=(--context "${kube_context}")

  info "juicefs-rwx-check: checking JuiceFS RWX write/read behavior"
  rwx_write_read_check_run "${namespace}" "${pvc_name}" "${image_ref}" "${kubectl_bin}" "${kubectl_args[@]}"
}

offline_install_wait_keycloak_ready() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  info "install-offline: waiting for Keycloak Deployment readiness"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" rollout status deployment/keycloak --timeout=240s
}

offline_install_wait_local_openai_ready() {
  local cache_dir="$1"
  local env_file="$2"
  local namespace
  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  info "install-offline: waiting for local OpenAI provider Deployment readiness"
  offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" rollout status deployment/agentsmith-lite-local-openai --timeout=120s
}

offline_install_bootstrap_keycloak() {
  local cache_dir="$1"
  local env_file="$2"
  local render_dir="$3"
  local namespace job_name
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  job_name="agentsmith-lite-keycloak-bootstrap"

  info "install-offline: bootstrapping Keycloak realm and client"
  offline_install_run_once_job \
    "${cache_dir}" \
    "${env_file}" \
    "${namespace}" \
    "${job_name}" \
    "${render_dir}/keycloak-bootstrap-job.yaml" \
    "180s" \
    "Keycloak bootstrap Job apply failed; refusing to continue" \
    "Keycloak bootstrap Job failed; refusing to continue"
}

offline_install_init_minio_bucket() {
  local cache_dir="$1"
  local env_file="$2"
  local render_dir="$3"
  local namespace bucket job_name logs apply_status wait_status logs_status
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  bucket="$(env_value_or_empty "${env_file}" S3_BUCKET)"
  job_name="agentsmith-lite-minio-bucket-init"
  minio_validate_bucket_name "${bucket}"
  info "install-offline: initializing MinIO bucket"
  offline_install_delete_job_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"

  set +e
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/minio-bucket-init-job.yaml"
  apply_status=$?
  wait_status=0
  logs_status=0
  logs=""
  if [[ "${apply_status}" -eq 0 ]]; then
    offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" wait --for=condition=complete "job/${job_name}" --timeout=120s
    wait_status=$?
    logs="$(offline_install_kubectl "${cache_dir}" "${env_file}" -n "${namespace}" logs "job/${job_name}" 2>&1)"
    logs_status=$?
  fi
  set -e

  if [[ "${apply_status}" -ne 0 ]]; then
    die "MinIO bucket init Job apply failed; refusing to continue"
  fi
  if [[ "${wait_status}" -ne 0 ]]; then
    offline_install_describe_job_failure_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"
    die "MinIO bucket init Job failed; refusing to continue"
  fi
  if [[ "${logs_status}" -ne 0 ]]; then
    offline_install_describe_job_failure_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"
    die "MinIO bucket init Job logs could not be read; refusing to continue"
  fi
  if ! grep -Fq "minio bucket ready" <<<"${logs}"; then
    offline_install_describe_job_failure_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"
    die "MinIO bucket init Job did not confirm bucket readiness"
  fi
  offline_install_delete_job_best_effort "${cache_dir}" "${env_file}" "${namespace}" "${job_name}"
}

offline_install_format_juicefs() {
  local cache_dir="$1"
  local env_file="$2"
  local render_dir="$3"
  local namespace job_name
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  job_name="agentsmith-lite-juicefs-format"

  info "install-offline: formatting JuiceFS volume"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/juicefs-secret.yaml"
  offline_install_run_once_job \
    "${cache_dir}" \
    "${env_file}" \
    "${namespace}" \
    "${job_name}" \
    "${render_dir}/juicefs-format-job.yaml" \
    "120s" \
    "JuiceFS format Job apply failed; refusing to apply JuiceFS PVC contract" \
    "JuiceFS format Job failed; refusing to apply JuiceFS PVC contract"
}

offline_install_init_postgres_databases() {
  local cache_dir="$1"
  local env_file="$2"
  local render_dir="$3"
  local namespace job_name
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  info "install-offline: initializing PostgreSQL app and JuiceFS metadata databases"
  job_name="agentsmith-lite-postgres-init"
  offline_install_run_once_job \
    "${cache_dir}" \
    "${env_file}" \
    "${namespace}" \
    "${job_name}" \
    "${render_dir}/postgres-init-job.yaml" \
    "120s" \
    "Postgres init Job apply failed; refusing to continue" \
    "Postgres init Job failed; refusing to continue"
}

run_p1_real_existing_cloud_install() {
  info "install-offline: existing-cloud mode; skipping self-hosted PostgreSQL, MinIO, and k3s mutation"
}

run_p1_real_offline_install() {
  local cache_dir="$1"
  local env_file="$2"
  local secrets_file="$3"
  local output_dir="$4"
  local render_dir namespace_manifest rendered_namespace_manifest skip_k3s

  render_dir="${output_dir}/rendered/offline-install"
  namespace_manifest="$(cache_relative_path "${cache_dir}" "manifests/namespace-bootstrap/namespace.yaml" "namespace bootstrap manifest")"
  rendered_namespace_manifest="${render_dir}/namespace.yaml"
  skip_k3s="$(env_value_or_empty "${env_file}" KUBERNETES_SKIP_K3S)"

  postgres_validate_self_hosted_urls "${env_file}" "${secrets_file}"
  minio_validate_self_hosted_env "${env_file}" "${secrets_file}"
  if [[ "${skip_k3s}" == "true" ]]; then
    need_file "$(env_value_or_empty "${env_file}" KUBECONFIG_PATH)"
    info "install-offline: kubernetes.skipK3s=true; using existing kubeconfig and skipping k3s installer plus k3s image import"
  else
    offline_install_run_k3s_installer "${cache_dir}" "${env_file}" "${output_dir}"
    offline_install_import_images "${cache_dir}"
    offline_install_run_coredns_service_lookup "${cache_dir}" "${env_file}"
  fi

  offline_install_render_namespace_manifest "${namespace_manifest}" "${rendered_namespace_manifest}" "${env_file}"
  info "install-offline: applying rendered namespace bootstrap"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${rendered_namespace_manifest}"

  offline_install_render_manifests "${cache_dir}" "${env_file}" "${secrets_file}" "${render_dir}"

  if [[ "$(env_value_or_empty "${env_file}" AUTH_MODE)" == "oidc" ]]; then
    local_ingress_tls_trust_ca "$(dirname "${env_file}")/local-ingress-tls"
    local_ingress_tls_ensure_hosts \
      "$(env_value_or_empty "${env_file}" APP_PUBLIC_BASE_URL)" \
      "${keycloak_public_base_url}"
    offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/app-ingress-tls-secret.yaml"
    offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/keycloak-ingress-tls-secret.yaml"
  fi

  offline_install_install_juicefs_csi_chart "${cache_dir}" "${env_file}" "${render_dir}"

  info "install-offline: applying rendered Postgres manifests"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/postgres-secret.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/postgres.yaml"
  offline_install_wait_postgres_ready "${cache_dir}" "${env_file}"
  offline_install_init_postgres_databases "${cache_dir}" "${env_file}" "${render_dir}"
  info "install-offline: applying rendered MinIO manifests"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/minio-secret.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/minio.yaml"
  offline_install_wait_minio_ready "${cache_dir}" "${env_file}"
  offline_install_init_minio_bucket "${cache_dir}" "${env_file}" "${render_dir}"

  offline_install_format_juicefs "${cache_dir}" "${env_file}" "${render_dir}"
  info "install-offline: applying rendered JuiceFS CSI contract"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/juicefs-storageclass-pvc.yaml"
  offline_install_wait_juicefs_pvc_bound "${cache_dir}" "${env_file}"
  offline_install_check_juicefs_rwx_write_read "${cache_dir}" "${env_file}"

  info "install-offline: applying rendered local OpenAI provider"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/local-openai-secret.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/local-openai-tls-secret.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/local-openai-ca.yaml"
  offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/local-openai.yaml"
  offline_install_wait_local_openai_ready "${cache_dir}" "${env_file}"

  if [[ "$(env_value_or_empty "${env_file}" AUTH_MODE)" == "oidc" ]]; then
    info "install-offline: applying rendered Keycloak manifests"
    offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/keycloak-secret.yaml"
    offline_install_kubectl "${cache_dir}" "${env_file}" apply -f "${render_dir}/keycloak.yaml"
    offline_install_wait_keycloak_ready "${cache_dir}" "${env_file}"
    offline_install_bootstrap_keycloak "${cache_dir}" "${env_file}" "${render_dir}"
  fi
}
