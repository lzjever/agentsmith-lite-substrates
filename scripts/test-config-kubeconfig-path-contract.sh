#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "${ROOT_DIR}/scripts/lib/config.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
config_dir="${tmp_dir}/configs"
mkdir -p "${config_dir}/state"
touch "${config_dir}/state/existing.kubeconfig"

write_config() {
  local file="$1"
  local skip_k3s="$2"
  local kubeconfig_path="$3"
  local kubeconfig_output="$4"
  local kube_context="${5:-}"

  cat >"${file}" <<EOF_CONFIG
mode: self-hosted
kubernetes:
  distribution: k3s
  namespace: agentsmith
  skipK3s: ${skip_k3s}
  kubeconfigPath: ${kubeconfig_path}
  kubeconfigOutput: ${kubeconfig_output}
  context: ${kube_context}
objectStorage:
  provider: minio
  bucket: agentsmith-lite-files
juicefs:
  storageClass: agentsmith-lite-juicefs-rwx
  pvcName: agentsmith-lite-files
auth:
  mode: builtin_admin
ingress:
  publicBaseUrl: http://localhost:3000
EOF_CONFIG
}

path_config="${config_dir}/path.yaml"
write_config "${path_config}" true state/../state/existing.kubeconfig generated/../generated/kubeconfig
write_env_contract_from_config "${path_config}" "${tmp_dir}/path-output" test true
grep -Fx "KUBECONFIG_PATH=${config_dir}/state/existing.kubeconfig" "${tmp_dir}/path-output/substrate.env" >/dev/null \
  || { printf 'expected kubeconfigPath to be absolute relative to config file\n' >&2; exit 1; }

output_config="${config_dir}/output.yaml"
write_config "${output_config}" false '' generated/../generated/kubeconfig
write_env_contract_from_config "${output_config}" "${tmp_dir}/output-output" test true
grep -Fx "KUBECONFIG_PATH=${config_dir}/generated/kubeconfig" "${tmp_dir}/output-output/substrate.env" >/dev/null \
  || { printf 'expected kubeconfigOutput to be absolute relative to config file\n' >&2; exit 1; }
grep -Fx 'KUBE_CONTEXT=default' "${tmp_dir}/output-output/substrate.env" >/dev/null \
  || { printf 'expected generated self-hosted k3s kubeconfig context to default to default\n' >&2; exit 1; }

explicit_context_config="${config_dir}/explicit-context.yaml"
write_config "${explicit_context_config}" false '' generated/kubeconfig workstation-admin
write_env_contract_from_config "${explicit_context_config}" "${tmp_dir}/explicit-context-output" test true
grep -Fx 'KUBE_CONTEXT=workstation-admin' "${tmp_dir}/explicit-context-output/substrate.env" >/dev/null \
  || { printf 'expected explicit self-hosted kubeconfig context to be preserved\n' >&2; exit 1; }

skip_context_config="${config_dir}/skip-context.yaml"
write_config "${skip_context_config}" true state/existing.kubeconfig ''
write_env_contract_from_config "${skip_context_config}" "${tmp_dir}/skip-context-output" test true
grep -Fx 'KUBE_CONTEXT=' "${tmp_dir}/skip-context-output/substrate.env" >/dev/null \
  || { printf 'expected skipK3s without an explicit context to leave KUBE_CONTEXT empty\n' >&2; exit 1; }

cloud_context_config="${config_dir}/cloud-context.yaml"
cat >"${cloud_context_config}" <<EOF_CONFIG
mode: existing-cloud
kubernetes:
  namespace: agentsmith
  kubeconfigPath: state/existing.kubeconfig
  context: production-admin
postgres:
  appUrlFromEnv: POSTGRES_APP_URL
  juicefsMetaUrlFromEnv: JUICEFS_META_URL
objectStorage:
  provider: s3
  bucket: agentsmith-lite-files
  accessKeyFromEnv: S3_ACCESS_KEY
  secretKeyFromEnv: S3_SECRET_KEY
juicefs:
  storageClass: agentsmith-lite-juicefs-rwx
  pvcName: agentsmith-lite-files
auth:
  mode: builtin_admin
ingress:
  publicBaseUrl: https://agentsmith.example.com
EOF_CONFIG
POSTGRES_APP_URL='postgresql://agentsmith:password@postgres.example.com:5432/agentsmith' \
JUICEFS_META_URL='postgres://juicefs:password@postgres.example.com:5432/juicefs_meta' \
S3_ACCESS_KEY='access-key' \
S3_SECRET_KEY='secret-key' \
write_env_contract_from_config "${cloud_context_config}" "${tmp_dir}/cloud-context-output" test true
grep -Fx 'KUBE_CONTEXT=production-admin' "${tmp_dir}/cloud-context-output/substrate.env" >/dev/null \
  || { printf 'expected explicit existing-cloud kubeconfig context to be preserved\n' >&2; exit 1; }

printf 'config kubeconfig path contract passed\n'
