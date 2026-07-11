#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "${ROOT_DIR}/scripts/lib/config.sh"
# shellcheck source=lib/keycloak.sh
source "${ROOT_DIR}/scripts/lib/keycloak.sh"
# shellcheck source=lib/local_ingress_tls.sh
source "${ROOT_DIR}/scripts/lib/local_ingress_tls.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

require_env_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(env_value_or_empty "${file}" "${key}")"
  [[ "${actual}" == "${expected}" ]] || die "${key} expected ${expected}, got ${actual}"
}

secret_data_value() {
  local file="$1"
  local key="$2"
  local encoded
  encoded="$(awk -v wanted="${key}" '$1 == wanted ":" { print $2; found=1 } END { if (!found) exit 1 }' "${file}")"
  if printf '%s' "${encoded}" | base64 --decode 2>/dev/null; then
    return 0
  fi
  printf '%s' "${encoded}" | base64 -D
}

write_config() {
  local file="$1"
  local public_base_url="$2"
  cat >"${file}" <<EOF_CONFIG
mode: self-hosted
kubernetes:
  distribution: k3s
  appNamespace: agentsmith-app
  substrateNamespace: agentsmith-substrate
  skipK3s: false
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
    publicBaseUrl: https://keycloak.agentsmith.example.test
ingress:
  publicBaseUrl: ${public_base_url}
  ingressClass: traefik
  tlsSecretName: agentsmith-lite-local-ingress-tls
EOF_CONFIG
}

check_generated_app_public_base_url() {
  local public_base_url="$1"
  local expected="$2"
  local name="$3"
  local config_file="${tmp_dir}/${name}.yaml"
  local output_dir="${tmp_dir}/${name}-out"

  write_config "${config_file}" "${public_base_url}"
  write_env_contract_from_config "${config_file}" "${output_dir}" "check-keycloak-oidc-contract" false >/dev/null
  require_env_value "${output_dir}/substrate.env" APP_PUBLIC_BASE_URL "${expected}"
}

check_rejected_app_public_base_url() {
  local public_base_url="$1"
  local name="$2"
  local config_file="${tmp_dir}/${name}.yaml"
  local output_dir="${tmp_dir}/${name}-out"

  write_config "${config_file}" "${public_base_url}"
  if (write_env_contract_from_config "${config_file}" "${output_dir}" "check-keycloak-oidc-contract" false) >/dev/null 2>&1; then
    die "expected ingress.publicBaseUrl to be rejected: ${public_base_url}"
  fi
}

config_file="${tmp_dir}/substrates.yaml"
output_dir="${tmp_dir}/out"
secret_rendered="${tmp_dir}/keycloak-secret.yaml"
app_tls_rendered="${tmp_dir}/app-ingress-tls-secret.yaml"
keycloak_tls_rendered="${tmp_dir}/keycloak-ingress-tls-secret.yaml"
cert_dir="${tmp_dir}/local-ingress-tls"
drift_env_file="${tmp_dir}/substrate-drift.env"
drift_secret_rendered="${tmp_dir}/keycloak-secret-drift.yaml"
expected_app_public_base_url="https://agentsmith.example.test/app"

write_config "${config_file}" "https://agentsmith.example.test/app//"

write_env_contract_from_config "${config_file}" "${output_dir}" "check-keycloak-oidc-contract" false >/dev/null

require_env_value "${output_dir}/substrate.env" APP_PUBLIC_BASE_URL "${expected_app_public_base_url}"
require_env_value "${output_dir}/substrate.env" KUBE_NAMESPACE "agentsmith-app"
require_env_value "${output_dir}/substrate.env" SUBSTRATE_NAMESPACE "agentsmith-substrate"
require_env_value "${output_dir}/substrate.env" OIDC_BACKCHANNEL_BASE_URL "http://keycloak.agentsmith-substrate.svc.cluster.local:8080/realms/agentsmith"
require_env_value "${output_dir}/substrate.env" APP_INGRESS_CLASS "traefik"
require_env_value "${output_dir}/substrate.env" APP_INGRESS_TRAEFIK_ENTRYPOINTS "websecure"
require_env_value "${output_dir}/substrate.env" APP_TLS_SECRET_NAME "agentsmith-lite-local-ingress-tls"
validate_env_contract "${output_dir}/substrate.env" "${output_dir}/substrate.secrets.env" >/dev/null

keycloak_prepare_self_hosted_context "${output_dir}/substrate.env" "${output_dir}/substrate.secrets.env"
local_ingress_tls_ensure "${cert_dir}" "${expected_app_public_base_url}" "${keycloak_public_base_url}"
tls_fingerprint_before="$(sha256sum "${cert_dir}/tls.crt" | awk '{print $1}')"
local_ingress_tls_ensure "${cert_dir}" "${expected_app_public_base_url}" "${keycloak_public_base_url}"
[[ "$(sha256sum "${cert_dir}/tls.crt" | awk '{print $1}')" == "${tls_fingerprint_before}" ]] \
  || die "local ingress TLS must reuse a certificate when its two hosts are unchanged"
render_local_ingress_tls_secret "${app_tls_rendered}" "agentsmith-app" "agentsmith-lite-local-ingress-tls" "${cert_dir}"
render_local_ingress_tls_secret "${keycloak_tls_rendered}" "agentsmith-substrate" "agentsmith-lite-local-ingress-tls" "${cert_dir}"
render_keycloak_secret_manifest "${secret_rendered}"
render_keycloak_deployment_manifest "${ROOT_DIR}/manifests/keycloak" "${tmp_dir}/keycloak.yaml" "quay.io/keycloak/keycloak@sha256:$(printf 'a%.0s' {1..64})"

grep -Fx '    traefik.ingress.kubernetes.io/router.entrypoints: websecure' "${tmp_dir}/keycloak.yaml" >/dev/null \
  || die "self-hosted Keycloak Traefik ingress must only bind websecure"

grep -A1 -F 'name: KC_HOSTNAME_STRICT' "${tmp_dir}/keycloak.yaml" | grep -Fx '              value: "true"' >/dev/null \
  || die "Keycloak must fix its configured HTTPS public hostname behind Traefik"

openssl x509 -in "${cert_dir}/tls.crt" -noout -ext subjectAltName | grep -F "DNS:agentsmith.example.test" >/dev/null \
  || die "local ingress certificate must include the app host SAN"
openssl x509 -in "${cert_dir}/tls.crt" -noout -ext subjectAltName | grep -F "DNS:keycloak.agentsmith.example.test" >/dev/null \
  || die "local ingress certificate must include the Keycloak host SAN"
grep -Fx '  namespace: agentsmith-app' "${app_tls_rendered}" >/dev/null \
  || die "app ingress TLS Secret must render in KUBE_NAMESPACE"
grep -Fx '  namespace: agentsmith-substrate' "${keycloak_tls_rendered}" >/dev/null \
  || die "Keycloak ingress TLS Secret must render in SUBSTRATE_NAMESPACE"
grep -Fx '  name: agentsmith-lite-local-ingress-tls' "${app_tls_rendered}" "${keycloak_tls_rendered}" >/dev/null \
  || die "both ingress TLS Secrets must use APP_TLS_SECRET_NAME"

app_public_base_url="$(secret_data_value "${secret_rendered}" appPublicBaseUrl)"
[[ "${app_public_base_url}" == "${expected_app_public_base_url}" ]] \
  || die "Keycloak appPublicBaseUrl expected ${expected_app_public_base_url}, got ${app_public_base_url}"
keycloak_jdbc_url="$(secret_data_value "${secret_rendered}" dbJdbcUrl)"
[[ "${keycloak_jdbc_url}" == "jdbc:postgresql://postgres.agentsmith-substrate.svc.cluster.local:5432/keycloak" ]] \
  || die "Keycloak dbJdbcUrl must target Postgres in SUBSTRATE_NAMESPACE"

if grep -R "https://agentsmith.example.test/app//" "${output_dir}" "${secret_rendered}" >/dev/null; then
  die "Keycloak/OIDC rendered output must not contain an unnormalized /app// public base URL"
fi

sed 's|^APP_PUBLIC_BASE_URL=.*|APP_PUBLIC_BASE_URL=https://agentsmith.example.test/app//|' \
  "${output_dir}/substrate.env" >"${drift_env_file}"
keycloak_prepare_self_hosted_context "${drift_env_file}" "${output_dir}/substrate.secrets.env"
render_keycloak_secret_manifest "${drift_secret_rendered}"
app_public_base_url="$(secret_data_value "${drift_secret_rendered}" appPublicBaseUrl)"
[[ "${app_public_base_url}" == "${expected_app_public_base_url}" ]] \
  || die "Keycloak appPublicBaseUrl must normalize env drift; expected ${expected_app_public_base_url}, got ${app_public_base_url}"
if grep -R "https://agentsmith.example.test/app//" "${drift_secret_rendered}" >/dev/null; then
  die "Keycloak rendered output must not contain an unnormalized env drift public base URL"
fi

check_generated_app_public_base_url "https://agentsmith.example.test/" "https://agentsmith.example.test" "root-slash"
check_generated_app_public_base_url "https://agentsmith.example.test" "https://agentsmith.example.test" "root-noslash"
check_generated_app_public_base_url "https://agentsmith.example.test/app/" "https://agentsmith.example.test/app" "path-slash"
check_generated_app_public_base_url "https://agentsmith.example.test:8443/app/" "https://agentsmith.example.test:8443/app" "valid-port"
check_generated_app_public_base_url "https://[::1]:8443/app/" "https://[::1]:8443/app" "valid-bracket-ipv6-port"

check_rejected_app_public_base_url "https://agentsmith.example.test/app?x=1" "query"
check_rejected_app_public_base_url "https://agentsmith.example.test/app#x" "fragment"
check_rejected_app_public_base_url "https://?x=1" "empty-host-query"
check_rejected_app_public_base_url "https://#x" "empty-host-fragment"
check_rejected_app_public_base_url "https://" "empty-host"
check_rejected_app_public_base_url "https://agentsmith example.test/app" "host-whitespace"
check_rejected_app_public_base_url "https://user@agentsmith.example.test/app" "userinfo"
check_rejected_app_public_base_url "https://agentsmith.example.test:bad/app" "invalid-port"
check_rejected_app_public_base_url "https://agentsmith.example.test:65536/app" "port-65536"
check_rejected_app_public_base_url "https://[::1]:99999/app" "ipv6-port-99999"
check_rejected_app_public_base_url "https://[::1/app" "malformed-bracket-authority"

if (write_config "${tmp_dir}/http-app.yaml" "http://agentsmith.example.test" && write_env_contract_from_config "${tmp_dir}/http-app.yaml" "${tmp_dir}/http-app-out" test false) >/dev/null 2>&1; then
  die "self-hosted OIDC must reject an HTTP app public URL"
fi
sed '/  ingressClass: traefik/d' "${config_file}" >"${tmp_dir}/no-ingress-class.yaml"
if (write_env_contract_from_config "${tmp_dir}/no-ingress-class.yaml" "${tmp_dir}/no-ingress-class-out" test false) >/dev/null 2>&1; then
  die "self-hosted OIDC must require an ingress class"
fi
sed '/  tlsSecretName: agentsmith-lite-local-ingress-tls/d' "${config_file}" >"${tmp_dir}/no-tls-secret.yaml"
if (write_env_contract_from_config "${tmp_dir}/no-tls-secret.yaml" "${tmp_dir}/no-tls-secret-out" test false) >/dev/null 2>&1; then
  die "self-hosted OIDC must require a TLS Secret name"
fi

info "Keycloak/OIDC public base URL contract validated: ${expected_app_public_base_url}"
