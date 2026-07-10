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

  cat >"${file}" <<EOF_CONFIG
mode: self-hosted
kubernetes:
  distribution: k3s
  namespace: agentsmith
  skipK3s: ${skip_k3s}
  kubeconfigPath: ${kubeconfig_path}
  kubeconfigOutput: ${kubeconfig_output}
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

printf 'config kubeconfig path contract passed\n'
