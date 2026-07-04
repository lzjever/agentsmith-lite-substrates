#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/juicefs.sh
source "${ROOT_DIR}/scripts/lib/juicefs.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/validate-juicefs-contract.sh --env out/substrate.env --secrets out/substrate.secrets.env [--manifests manifests/juicefs-csi]

Checks the static JuiceFS CSI contract owned by substrates:
  - env points at csi.juicefs.com, an RWX StorageClass, and a PVC name
  - manifest templates render env/config names into Secret, StorageClass, and PVC
  - rendered Secret, StorageClass, and PVC cross-check namespace, secretName,
    storageClass, pvcName, RWX, and the JuiceFS bucket URL
  - raw S3/JuiceFS credentials remain substrate/CSI scoped and redacted
EOF_USAGE
}

env_file=""
secrets_file=""
manifest_dir="${ROOT_DIR}/manifests/juicefs-csi"

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
    --manifests)
      manifest_dir="${2:-}"
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

validate_env_contract "${env_file}" "${secrets_file}" >/dev/null

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

require_line() {
  local file="$1"
  local expected="$2"
  local message="$3"
  grep -Fxq "${expected}" "${file}" || die "${message}"
}

secret_rendered="${tmp_dir}/secret.yaml"
storage_rendered="${tmp_dir}/storageclass-pvc.yaml"
render_juicefs_contract "${env_file}" "${secrets_file}" "${manifest_dir}" "${tmp_dir}"
mv "${tmp_dir}/juicefs-secret.yaml" "${secret_rendered}"
mv "${tmp_dir}/juicefs-storageclass-pvc.yaml" "${storage_rendered}"

namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
volume_name="$(env_value_or_empty "${env_file}" JUICEFS_VOLUME_NAME)"
bucket_url="$(env_value_or_empty "${env_file}" JUICEFS_BUCKET)"
secret_name="$(env_value_or_empty "${env_file}" JUICEFS_SECRET_NAME)"
driver="$(env_value_or_empty "${env_file}" JUICEFS_CSI_DRIVER)"
storage_class="$(env_value_or_empty "${env_file}" JUICEFS_STORAGE_CLASS)"
pvc_name="$(env_value_or_empty "${env_file}" JUICEFS_PVC_NAME)"
s3_bucket="$(env_value_or_empty "${env_file}" S3_BUCKET)"

[[ "${bucket_url}" =~ ^s3:// ]] || die "JUICEFS_BUCKET must be a bucket URL such as s3://bucket/path/"
[[ "${bucket_url}" != "${s3_bucket}" ]] || die "JUICEFS_BUCKET must be a bucket URL, not the plain S3_BUCKET name"

require_line "${secret_rendered}" "  name: ${secret_name}" "rendered JuiceFS Secret metadata.name must match JUICEFS_SECRET_NAME"
require_line "${secret_rendered}" "  namespace: ${namespace}" "rendered JuiceFS Secret namespace must match KUBE_NAMESPACE"
require_line "${secret_rendered}" "  name: ${volume_name}" "rendered JuiceFS Secret stringData.name must match JUICEFS_VOLUME_NAME"
require_line "${secret_rendered}" "  storage: s3" "rendered JuiceFS Secret storage must be s3"
require_line "${secret_rendered}" "  bucket: ${bucket_url}" "rendered JuiceFS Secret bucket must match the full JUICEFS_BUCKET URL"
for key in metaurl access-key secret-key; do
  grep -Eq "^[[:space:]]{2}${key}:[[:space:]]*.+" "${secret_rendered}" \
    || die "rendered JuiceFS Secret is missing non-empty stringData.${key}"
done

require_line "${storage_rendered}" "  name: ${storage_class}" "rendered JuiceFS StorageClass metadata.name must match JUICEFS_STORAGE_CLASS"
require_line "${storage_rendered}" "provisioner: ${driver}" "rendered JuiceFS StorageClass provisioner must match JUICEFS_CSI_DRIVER"
require_line "${storage_rendered}" "reclaimPolicy: Retain" "JuiceFS StorageClass must make reclaim policy explicit"
require_line "${storage_rendered}" "  csi.storage.k8s.io/provisioner-secret-name: ${secret_name}" "rendered StorageClass provisioner secret name must match JUICEFS_SECRET_NAME"
require_line "${storage_rendered}" "  csi.storage.k8s.io/provisioner-secret-namespace: ${namespace}" "rendered StorageClass provisioner secret namespace must match KUBE_NAMESPACE"
require_line "${storage_rendered}" "  csi.storage.k8s.io/node-publish-secret-name: ${secret_name}" "rendered StorageClass node-publish secret name must match JUICEFS_SECRET_NAME"
require_line "${storage_rendered}" "  csi.storage.k8s.io/node-publish-secret-namespace: ${namespace}" "rendered StorageClass node-publish secret namespace must match KUBE_NAMESPACE"
require_line "${storage_rendered}" "  name: ${pvc_name}" "rendered JuiceFS PVC metadata.name must match JUICEFS_PVC_NAME"
require_line "${storage_rendered}" "  namespace: ${namespace}" "rendered JuiceFS PVC namespace must match KUBE_NAMESPACE"
require_line "${storage_rendered}" "    - ReadWriteMany" "JuiceFS PVC must request ReadWriteMany"
require_line "${storage_rendered}" "  storageClassName: ${storage_class}" "rendered JuiceFS PVC storageClassName must match JUICEFS_STORAGE_CLASS"

info "JuiceFS CSI contract validated: driver=$(env_value_or_empty "${env_file}" JUICEFS_CSI_DRIVER) storageClass=$(env_value_or_empty "${env_file}" JUICEFS_STORAGE_CLASS) pvc=$(env_value_or_empty "${env_file}" JUICEFS_PVC_NAME)"
info "secret boundary: JuiceFS CSI raw credentials are rendered only into ${manifest_dir}/secret.example.yaml shape, not app workload env"
