#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

local_ingress_tls_b64() {
  base64 <"$1" | tr -d '\n'
}

local_ingress_tls_host() {
  local url="$1"
  local authority

  case "${url}" in
    https://*) authority="${url#https://}" ;;
    *) die "local ingress TLS requires an https URL" ;;
  esac
  authority="${authority%%/*}"
  [[ -n "${authority}" && "${authority}" != *:* && "${authority}" != *'['* ]] \
    || die "local ingress TLS requires a DNS host without a port"
  printf '%s\n' "${authority}"
}

local_ingress_tls_run_openssl() {
  local message="$1"
  shift
  local stderr_output

  if stderr_output="$(openssl "$@" 2>&1 >/dev/null)"; then
    return 0
  fi
  die "${message}; openssl stderr: ${stderr_output}"
}

local_ingress_tls_ensure() {
  local cert_dir="$1"
  local app_url="$2"
  local keycloak_url="$3"
  local app_host keycloak_host expected_hosts

  command -v openssl >/dev/null 2>&1 || die "openssl is required to generate local ingress TLS certificates"
  app_host="$(local_ingress_tls_host "${app_url}")"
  keycloak_host="$(local_ingress_tls_host "${keycloak_url}")"
  [[ "${app_host}" != "${keycloak_host}" ]] || die "local app and Keycloak ingress hosts must differ"
  expected_hosts="${app_host}\n${keycloak_host}"

  umask 077
  mkdir -p "${cert_dir}"
  chmod 0700 "${cert_dir}"
  if [[ ! -s "${cert_dir}/ca.key" || ! -s "${cert_dir}/ca.crt" ]]; then
    rm -f "${cert_dir}/ca.key" "${cert_dir}/ca.crt"
    local_ingress_tls_run_openssl "openssl failed to generate local ingress CA key" genrsa -out "${cert_dir}/ca.key" 2048
    local_ingress_tls_run_openssl "openssl failed to generate local ingress CA certificate" \
      req -x509 -new -nodes -key "${cert_dir}/ca.key" -sha256 -days 3650 \
      -subj "/CN=agentsmith-lite-local-ingress-ca" -out "${cert_dir}/ca.crt"
  fi

  if [[ ! -s "${cert_dir}/hosts" || "$(<"${cert_dir}/hosts")" != "$(printf '%b' "${expected_hosts}")" || ! -s "${cert_dir}/tls.key" || ! -s "${cert_dir}/tls.crt" ]]; then
    printf '%b\n' "${expected_hosts}" >"${cert_dir}/hosts"
    local_ingress_tls_run_openssl "openssl failed to generate local ingress server key" genrsa -out "${cert_dir}/tls.key" 2048
    cat >"${cert_dir}/server.cnf" <<EOF_CONF
[req]
distinguished_name=req_distinguished_name
req_extensions=v3_req
prompt=no

[req_distinguished_name]
CN=${app_host}

[v3_req]
subjectAltName=@alt_names

[alt_names]
DNS.1=${app_host}
DNS.2=${keycloak_host}
EOF_CONF
    local_ingress_tls_run_openssl "openssl failed to generate local ingress server CSR" \
      req -new -key "${cert_dir}/tls.key" -out "${cert_dir}/tls.csr" -config "${cert_dir}/server.cnf"
    local_ingress_tls_run_openssl "openssl failed to sign local ingress server certificate" \
      x509 -req -in "${cert_dir}/tls.csr" -CA "${cert_dir}/ca.crt" -CAkey "${cert_dir}/ca.key" -CAcreateserial \
      -out "${cert_dir}/tls.crt" -days 3650 -sha256 -extensions v3_req -extfile "${cert_dir}/server.cnf"
  fi
  chmod 0600 "${cert_dir}/ca.key" "${cert_dir}/tls.key"
}

local_ingress_tls_trust_ca() {
  local cert_dir="$1"
  local trust_dir trust_file trust_style

  [[ "$(id -u)" == "0" ]] || die "self-hosted local HTTPS requires root to trust its local CA"
  if command -v update-ca-certificates >/dev/null 2>&1; then
    trust_dir="/usr/local/share/ca-certificates"
    trust_style="debian"
  elif command -v update-ca-trust >/dev/null 2>&1; then
    trust_dir="/etc/ca-certificates/trust-source/anchors"
    trust_style="p11-kit"
  else
    die "self-hosted local HTTPS requires update-ca-certificates or update-ca-trust on this host"
  fi
  trust_file="${trust_dir}/agentsmith-lite-local-ingress-ca.crt"
  mkdir -p "${trust_dir}"
  if ! cmp -s "${cert_dir}/ca.crt" "${trust_file}"; then
    install -m 0644 "${cert_dir}/ca.crt" "${trust_file}"
    if [[ "${trust_style}" == "debian" ]]; then
      update-ca-certificates
    else
      update-ca-trust extract
    fi
  fi
}

local_ingress_tls_ensure_hosts() {
  local app_url="$1"
  local keycloak_url="$2"
  local app_host keycloak_host hosts_file tmp

  [[ "$(id -u)" == "0" ]] || die "self-hosted local HTTPS requires root to manage its local hosts entries"
  app_host="$(local_ingress_tls_host "${app_url}")"
  keycloak_host="$(local_ingress_tls_host "${keycloak_url}")"
  hosts_file="/etc/hosts"
  tmp="$(mktemp "${hosts_file}.agentsmith-lite.XXXXXX")"
  awk '
    $0 == "# BEGIN agentsmith-lite local ingress" { managed=1; next }
    $0 == "# END agentsmith-lite local ingress" { managed=0; next }
    !managed { print }
  ' "${hosts_file}" >"${tmp}"
  {
    printf '# BEGIN agentsmith-lite local ingress\n'
    printf '127.0.0.1 %s\n' "${app_host}"
    printf '127.0.0.1 %s\n' "${keycloak_host}"
    printf '# END agentsmith-lite local ingress\n'
  } >>"${tmp}"
  if ! cmp -s "${tmp}" "${hosts_file}"; then
    install -m 0644 "${tmp}" "${hosts_file}"
  fi
  rm -f "${tmp}"
}

render_local_ingress_tls_secret() {
  local output="$1"
  local namespace="$2"
  local secret_name="$3"
  local cert_dir="$4"
  local tmp="${output}.tmp"

  umask 077
  {
    printf 'apiVersion: v1\n'
    printf 'kind: Secret\n'
    printf 'metadata:\n'
    printf '  name: %s\n' "${secret_name}"
    printf '  namespace: %s\n' "${namespace}"
    printf 'type: kubernetes.io/tls\n'
    printf 'data:\n'
    printf '  tls.crt: %s\n' "$(local_ingress_tls_b64 "${cert_dir}/tls.crt")"
    printf '  tls.key: %s\n' "$(local_ingress_tls_b64 "${cert_dir}/tls.key")"
  } >"${tmp}"
  chmod 0600 "${tmp}"
  mv "${tmp}" "${output}"
}
