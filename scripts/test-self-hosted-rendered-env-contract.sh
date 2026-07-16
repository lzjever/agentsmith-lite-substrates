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

builtin_config="${config_dir}/builtin.yaml"
sed 's/mode: oidc/mode: builtin_admin/' "${config_file}" >"${builtin_config}"
if (write_env_contract_from_config "${builtin_config}" "${tmp_dir}/builtin-output" test true) >/dev/null 2>&1; then
  printf 'expected builtin_admin auth mode to be rejected\n' >&2
  exit 1
fi

require_line() {
  local file="$1"
  local line="$2"
  grep -Fx "${line}" "${file}" >/dev/null \
    || { printf 'expected %s in %s\n' "${line}" "${file}" >&2; exit 1; }
}

env_file="${output_dir}/substrate.env"
secrets_file="${output_dir}/substrate.secrets.env"
app_env_file="${output_dir}/app.env"
app_secrets_file="${output_dir}/app.secrets.env"
require_line "${env_file}" "KUBECONFIG_PATH=${config_dir}/out/kubeconfig"
require_line "${env_file}" 'KUBE_CONTEXT=default'
require_line "${env_file}" 'KUBE_NAMESPACE=agentsmith'
require_line "${env_file}" 'SUBSTRATE_NAMESPACE=agentsmith-substrate'
require_line "${env_file}" 'S3_ENDPOINT=http://minio.agentsmith-substrate.svc.cluster.local:9000'
require_line "${env_file}" 'JUICEFS_BUCKET=http://minio.agentsmith-substrate.svc.cluster.local:9000/agentsmith-lite-files'
require_line "${env_file}" 'OIDC_ISSUER_URL=https://keycloak.agentsmith.localhost/realms/agentsmith'
require_line "${env_file}" 'OIDC_BACKCHANNEL_BASE_URL=http://keycloak.agentsmith-substrate.svc.cluster.local:8080/realms/agentsmith'
require_line "${app_env_file}" 'AGENTSMITH_LITE_PRIVATE_PROVIDER_HOSTS=agentsmith-lite-local-openai.agentsmith.svc.cluster.local'

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
! grep -Fq 'BUILTIN_ADMIN_INITIAL_PASSWORD=' "${secrets_file}" \
  || { printf 'builtin admin secret must not be emitted by the OIDC-only substrate contract\n' >&2; exit 1; }

credential_encryption_key="$(env_value "${app_secrets_file}" APP_CREDENTIAL_ENCRYPTION_KEY)"
[[ "${credential_encryption_key}" =~ ^[A-Za-z0-9_-]{43}$ ]] \
  || { printf 'expected a base64url-encoded 32-byte app credential encryption key\n' >&2; exit 1; }
for non_secret_file in "${env_file}" "${app_env_file}"; do
  ! grep -Fq 'APP_CREDENTIAL_ENCRYPTION_KEY=' "${non_secret_file}" \
    || { printf 'app credential encryption key must not be written to %s\n' "${non_secret_file}" >&2; exit 1; }
done
! grep -Fq 'APP_CREDENTIAL_ENCRYPTION_KEY=' "${secrets_file}" \
  || { printf 'app credential encryption key must stay in the app-owned secrets overlay\n' >&2; exit 1; }

rerender_output="$(APP_CREDENTIAL_ENCRYPTION_KEY=operator-environment-must-not-rotate-existing-key \
  write_env_contract_from_config "${config_file}" "${output_dir}" test true 2>&1)"
[[ "$(env_value "${app_secrets_file}" APP_CREDENTIAL_ENCRYPTION_KEY)" == "${credential_encryption_key}" ]] \
  || { printf 'expected app credential encryption key to survive repeated rendering\n' >&2; exit 1; }
[[ "${rerender_output}" != *"${credential_encryption_key}"* ]] \
  || { printf 'app credential encryption key must not be printed during rendering\n' >&2; exit 1; }

contract_count="$(find "${output_dir}" -maxdepth 1 -type f -name 'substrate*.env' | wc -l | tr -d ' ')"
[[ "${contract_count}" == '2' ]] \
  || { printf 'expected one substrate env/secrets contract, found %s files\n' "${contract_count}" >&2; exit 1; }

printf 'self-hosted rendered env contract passed\n'
