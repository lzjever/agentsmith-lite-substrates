#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "${ROOT_DIR}/scripts/lib/config.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
config_dir="${tmp_dir}/config"
output_dir="${tmp_dir}/out"
mkdir -p "${config_dir}"

config_file="${config_dir}/substrates.yaml"
cat >"${config_file}" <<'EOF_CONFIG'
mode: self-hosted
kubernetes:
  distribution: k3s
  appNamespace: agentsmith
  substrateNamespace: agentsmith-substrate
  skipK3s: false
  kubeconfigOutput: out/kubeconfig
postgres:
  storageClass: local-path
objectStorage:
  provider: minio
  endpoint: http://minio.agentsmith-substrate.svc.cluster.local:9000
  region: us-east-1
  bucket: agentsmith-lite-files
juicefs:
  storageClass: agentsmith-lite-juicefs-rwx
  pvcName: agentsmith-lite-files
auth:
  mode: oidc
  realm: agentsmith
  clientId: agentsmith-lite
  keycloak:
    publicBaseUrl: https://keycloak.agentsmith.localhost
ingress:
  publicBaseUrl: https://agentsmith.localhost
  ingressClass: traefik
  tlsSecretName: agentsmith-lite-local-ingress-tls
EOF_CONFIG

write_env_contract_from_config "${config_file}" "${output_dir}" test true
validate_env_contract "${output_dir}/substrate.env" "${output_dir}/substrate.secrets.env"

require_line() {
  local file="$1"
  local line="$2"
  grep -Fx "${line}" "${file}" >/dev/null \
    || { printf 'expected %s in %s\n' "${line}" "${file}" >&2; exit 1; }
}

env_file="${output_dir}/substrate.env"
secrets_file="${output_dir}/substrate.secrets.env"
require_line "${env_file}" "KUBECONFIG_PATH=${config_dir}/out/kubeconfig"
require_line "${env_file}" 'KUBE_CONTEXT=default'
require_line "${env_file}" 'KUBE_NAMESPACE=agentsmith'
require_line "${env_file}" 'SUBSTRATE_NAMESPACE=agentsmith-substrate'
require_line "${env_file}" 'S3_ENDPOINT=http://minio.agentsmith-substrate.svc.cluster.local:9000'
require_line "${env_file}" 'JUICEFS_BUCKET=http://minio.agentsmith-substrate.svc.cluster.local:9000/agentsmith-lite-files'
require_line "${env_file}" 'OIDC_ISSUER_URL=https://keycloak.agentsmith.localhost/realms/agentsmith'
require_line "${env_file}" 'OIDC_BACKCHANNEL_BASE_URL=http://keycloak.agentsmith-substrate.svc.cluster.local:8080/realms/agentsmith'

postgres_app_url="$(env_value "${secrets_file}" POSTGRES_APP_URL)"
juicefs_meta_url="$(env_value "${secrets_file}" JUICEFS_META_URL)"
[[ "${postgres_app_url}" == *'@postgres.agentsmith-substrate.svc.cluster.local:5432/agentsmith_lite' ]] \
  || { printf 'expected local PostgreSQL service URL\n' >&2; exit 1; }
[[ "${juicefs_meta_url}" == *'@postgres.agentsmith-substrate.svc.cluster.local:5432/juicefs_meta' ]] \
  || { printf 'expected local JuiceFS metadata service URL\n' >&2; exit 1; }
[[ -n "$(env_value "${secrets_file}" S3_ACCESS_KEY)" ]] \
  || { printf 'expected local S3 access key\n' >&2; exit 1; }
[[ -n "$(env_value "${secrets_file}" S3_SECRET_KEY)" ]] \
  || { printf 'expected local S3 secret key\n' >&2; exit 1; }
[[ -n "$(env_value "${secrets_file}" OIDC_CLIENT_SECRET)" ]] \
  || { printf 'expected local OIDC client secret\n' >&2; exit 1; }

contract_count="$(find "${output_dir}" -maxdepth 1 -type f -name 'substrate*.env' | wc -l | tr -d ' ')"
[[ "${contract_count}" == '2' ]] \
  || { printf 'expected one substrate env/secrets contract, found %s files\n' "${contract_count}" >&2; exit 1; }

printf 'self-hosted rendered env contract passed\n'
