#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"

LOCAL_OPENAI_SERVICE_NAME="agentsmith-lite-local-openai"
LOCAL_OPENAI_CA_CONFIG_MAP="agentsmith-lite-local-openai-ca"
LOCAL_OPENAI_TLS_SECRET="agentsmith-lite-local-openai-tls"
LOCAL_OPENAI_API_KEY_SECRET="agentsmith-lite-local-openai-api-key"
LOCAL_OPENAI_SCRIPT_CONFIG_MAP="agentsmith-lite-local-openai-script"

local_openai_b64() {
  base64 <"$1" | tr -d '\n'
}

local_openai_value_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

local_openai_literal_file() {
  local file="$1"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '    %s\n' "${line}"
  done <"${file}"
}

local_openai_render_template() {
  local input="$1"
  local output="$2"
  local content="$3"
  if grep -Eq '\$\{[A-Z0-9_]+\}' <<<"${content}"; then
    die "local OpenAI manifest template has unresolved placeholders after rendering: ${input}"
  fi
  printf '%s\n' "${content}" >"${output}"
}

local_openai_generate_tls() {
  local cert_dir="$1"
  local namespace="$2"
  local cn="${LOCAL_OPENAI_SERVICE_NAME}.${namespace}.svc.cluster.local"

  command -v openssl >/dev/null 2>&1 \
    || die "openssl is required to generate local OpenAI provider TLS certificates"

  mkdir -p "${cert_dir}"
  openssl genrsa -out "${cert_dir}/ca.key" 2048 >/dev/null 2>&1 \
    || die "openssl failed to generate local OpenAI provider CA key"
  openssl req \
    -x509 \
    -new \
    -nodes \
    -key "${cert_dir}/ca.key" \
    -sha256 \
    -days 3650 \
    -subj "/CN=${LOCAL_OPENAI_CA_CONFIG_MAP}" \
    -out "${cert_dir}/ca.crt" >/dev/null 2>&1 \
    || die "openssl failed to generate local OpenAI provider CA certificate"
  openssl genrsa -out "${cert_dir}/tls.key" 2048 >/dev/null 2>&1 \
    || die "openssl failed to generate local OpenAI provider server key"
  cat >"${cert_dir}/server.cnf" <<EOF_CONF
[req]
distinguished_name=req_distinguished_name
req_extensions=v3_req
prompt=no

[req_distinguished_name]
CN=${cn}

[v3_req]
subjectAltName=@alt_names

[alt_names]
DNS.1=${LOCAL_OPENAI_SERVICE_NAME}
DNS.2=${LOCAL_OPENAI_SERVICE_NAME}.${namespace}
DNS.3=${LOCAL_OPENAI_SERVICE_NAME}.${namespace}.svc
DNS.4=${LOCAL_OPENAI_SERVICE_NAME}.${namespace}.svc.cluster.local
EOF_CONF
  openssl req \
    -new \
    -key "${cert_dir}/tls.key" \
    -out "${cert_dir}/tls.csr" \
    -config "${cert_dir}/server.cnf" >/dev/null 2>&1 \
    || die "openssl failed to generate local OpenAI provider server CSR"
  openssl x509 \
    -req \
    -in "${cert_dir}/tls.csr" \
    -CA "${cert_dir}/ca.crt" \
    -CAkey "${cert_dir}/ca.key" \
    -CAcreateserial \
    -out "${cert_dir}/tls.crt" \
    -days 3650 \
    -sha256 \
    -extensions v3_req \
    -extfile "${cert_dir}/server.cnf" >/dev/null 2>&1 \
    || die "openssl failed to sign local OpenAI provider server certificate"
}

render_local_openai_api_key_secret() {
  local output="$1"
  local namespace="$2"
  local api_key="$3"
  local tmp="${output}.tmp"
  local old_umask

  old_umask="$(umask)"
  umask 077
  {
    printf 'apiVersion: v1\n'
    printf 'kind: Secret\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "${LOCAL_OPENAI_API_KEY_SECRET}"
    printf '  namespace: %s\n' "${namespace}"
    printf 'type: Opaque\n'
    printf 'data:\n'
    printf '  apiKey: %s\n' "$(local_openai_value_b64 "${api_key}")"
  } >"${tmp}"
  umask "${old_umask}"
  chmod 0600 "${tmp}"
  mv "${tmp}" "${output}"
}

render_local_openai_tls_secret() {
  local output="$1"
  local namespace="$2"
  local cert_dir="$3"
  local tmp="${output}.tmp"
  local old_umask

  old_umask="$(umask)"
  umask 077
  {
    printf 'apiVersion: v1\n'
    printf 'kind: Secret\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "${LOCAL_OPENAI_TLS_SECRET}"
    printf '  namespace: %s\n' "${namespace}"
    printf 'type: kubernetes.io/tls\n'
    printf 'data:\n'
    printf '  tls.crt: %s\n' "$(local_openai_b64 "${cert_dir}/tls.crt")"
    printf '  tls.key: %s\n' "$(local_openai_b64 "${cert_dir}/tls.key")"
  } >"${tmp}"
  umask "${old_umask}"
  chmod 0600 "${tmp}"
  mv "${tmp}" "${output}"
}

render_local_openai_ca_config_map() {
  local output="$1"
  local namespace="$2"
  local cert_dir="$3"
  local tmp="${output}.tmp"

  {
    printf 'apiVersion: v1\n'
    printf 'kind: ConfigMap\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "${LOCAL_OPENAI_CA_CONFIG_MAP}"
    printf '  namespace: %s\n' "${namespace}"
    printf 'data:\n'
    printf '  ca.crt: |\n'
    local_openai_literal_file "${cert_dir}/ca.crt"
  } >"${tmp}"
  mv "${tmp}" "${output}"
}

render_local_openai_provider_manifest() {
  local manifest_dir="$1"
  local output="$2"
  local namespace="$3"
  local provider_image="$4"
  local content tmp

  need_file "${manifest_dir}/provider.py"
  need_file "${manifest_dir}/provider.yaml"
  require_digest_pinned_image_ref "local OpenAI provider image" "${provider_image}"

  tmp="${output}.tmp"
  content="$(<"${manifest_dir}/provider.yaml")"
  content="${content//\$\{KUBE_NAMESPACE\}/${namespace}}"
  content="${content//\$\{LOCAL_OPENAI_PROVIDER_IMAGE\}/${provider_image}}"
  {
    printf 'apiVersion: v1\n'
    printf 'kind: ConfigMap\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "${LOCAL_OPENAI_SCRIPT_CONFIG_MAP}"
    printf '  namespace: %s\n' "${namespace}"
    printf 'data:\n'
    printf '  provider.py: |\n'
    local_openai_literal_file "${manifest_dir}/provider.py"
    printf -- '---\n'
    printf '%s\n' "${content}"
  } >"${tmp}"
  local_openai_render_template "${manifest_dir}/provider.yaml" "${output}" "$(<"${tmp}")"
  rm -f "${tmp}"
}

render_local_openai_manifests() {
  local env_file="$1"
  local app_secrets_file="$2"
  local manifest_dir="$3"
  local render_dir="$4"
  local provider_image="$5"
  local namespace api_key cert_dir

  namespace="$(env_value_or_empty "${env_file}" KUBE_NAMESPACE)"
  [[ -n "${namespace}" ]] || die "KUBE_NAMESPACE must be set before rendering local OpenAI provider"
  need_file "${app_secrets_file}"
  api_key="$(env_value_or_empty "${app_secrets_file}" AGENTSMITH_LITE_MODEL_API_KEY_LOCAL)"
  [[ -n "${api_key}" ]] || die "AGENTSMITH_LITE_MODEL_API_KEY_LOCAL must be set before rendering local OpenAI provider"

  cert_dir="$(mktemp -d)"
  local_openai_generate_tls "${cert_dir}" "${namespace}"
  render_local_openai_api_key_secret "${render_dir}/local-openai-secret.yaml" "${namespace}" "${api_key}"
  render_local_openai_tls_secret "${render_dir}/local-openai-tls-secret.yaml" "${namespace}" "${cert_dir}"
  render_local_openai_ca_config_map "${render_dir}/local-openai-ca.yaml" "${namespace}" "${cert_dir}"
  render_local_openai_provider_manifest "${manifest_dir}" "${render_dir}/local-openai.yaml" "${namespace}" "${provider_image}"
  rm -rf -- "${cert_dir}"
}
