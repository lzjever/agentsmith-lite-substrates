#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/validate-juicefs-contract.sh --env out/substrate.env --secrets out/substrate.secrets.env [--manifests manifests/juicefs-csi]

Checks the static JuiceFS CSI contract owned by substrates:
  - env points at csi.juicefs.com, an RWX StorageClass, and a PVC name
  - manifest templates expose the CSI Secret keys JuiceFS expects
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
need_dir "${manifest_dir}"
need_file "${manifest_dir}/secret.example.yaml"
need_file "${manifest_dir}/storageclass-pvc.yaml"

grep -Fq 'provisioner: csi.juicefs.com' "${manifest_dir}/storageclass-pvc.yaml" \
  || die "JuiceFS StorageClass must use provisioner: csi.juicefs.com"
grep -Fq 'ReadWriteMany' "${manifest_dir}/storageclass-pvc.yaml" \
  || die "JuiceFS PVC must request ReadWriteMany"
grep -Fq 'reclaimPolicy:' "${manifest_dir}/storageclass-pvc.yaml" \
  || die "JuiceFS StorageClass must make reclaim policy explicit"

for key in name metaurl storage bucket access-key secret-key; do
  grep -Eq "^[[:space:]]{2}${key}:" "${manifest_dir}/secret.example.yaml" \
    || die "JuiceFS CSI Secret template is missing stringData.${key}"
done

info "JuiceFS CSI contract validated: driver=$(env_value_or_empty "${env_file}" JUICEFS_CSI_DRIVER) storageClass=$(env_value_or_empty "${env_file}" JUICEFS_STORAGE_CLASS) pvc=$(env_value_or_empty "${env_file}" JUICEFS_PVC_NAME)"
info "secret boundary: JuiceFS CSI raw credentials are rendered only into ${manifest_dir}/secret.example.yaml shape, not app workload env"
