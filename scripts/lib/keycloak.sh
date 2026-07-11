#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"

keycloak_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

keycloak_render_template() {
  local input="$1"
  local output="$2"
  local content="$3"
  if grep -Eq '\$\{[A-Z0-9_]+\}' <<<"${content}"; then
    die "Keycloak manifest template has unresolved placeholders after rendering: ${input}"
  fi
  printf '%s\n' "${content}" >"${output}"
}

keycloak_parse_public_base_url() {
  local url="$1"
  local rest authority path host

  case "${url}" in
    http://*) rest="${url#http://}" ;;
    https://*) rest="${url#https://}" ;;
    *) die "Keycloak public base URL must start with http:// or https://" ;;
  esac

  authority="${rest%%/*}"
  if [[ "${rest}" == */* ]]; then
    path="/${rest#*/}"
  else
    path="/"
  fi
  [[ -n "${authority}" ]] || die "Keycloak public base URL must include a host"

  if [[ "${authority}" == \[*\]* ]]; then
    host="${authority#\[}"
    host="${host%%\]*}"
  else
    host="${authority%%:*}"
  fi
  [[ -n "${host}" ]] || die "Keycloak public base URL must include a host"

  keycloak_ingress_host="${host}"
  keycloak_ingress_path="${path}"
}

keycloak_should_render_ingress() {
  case "${keycloak_ingress_host}" in
    localhost|127.0.0.1|::1)
      return 1
      ;;
  esac
  return 0
}

keycloak_ingress_manifest_block() {
  local ingress_class="$1"
  local tls_secret="$2"
  local traefik_entrypoints="$3"

  if ! keycloak_should_render_ingress; then
    return 0
  fi

  cat <<EOF_INGRESS
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: ${keycloak_namespace}
EOF_INGRESS
  if [[ "${ingress_class}" == "traefik" && "${traefik_entrypoints}" == "websecure" ]]; then
    cat <<EOF_INGRESS_ANNOTATIONS
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
EOF_INGRESS_ANNOTATIONS
  fi
  cat <<EOF_INGRESS
spec:
EOF_INGRESS
  if [[ -n "${ingress_class}" ]]; then
    cat <<EOF_INGRESS_CLASS
  ingressClassName: ${ingress_class}
EOF_INGRESS_CLASS
  fi
  if [[ -n "${tls_secret}" ]]; then
    cat <<EOF_INGRESS_TLS
  tls:
    - hosts:
        - ${keycloak_ingress_host}
      secretName: ${tls_secret}
EOF_INGRESS_TLS
  fi
  cat <<EOF_INGRESS_RULES
  rules:
    - host: ${keycloak_ingress_host}
      http:
        paths:
          - path: ${keycloak_ingress_path}
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 8080
EOF_INGRESS_RULES
}

keycloak_prepare_self_hosted_context() {
  local env_file="$1"
  local secrets_file="$2"
  local issuer

  [[ "$(env_value_or_empty "${env_file}" AUTH_MODE)" == "oidc" ]] \
    || die "self-hosted Keycloak render requires AUTH_MODE=oidc"
  issuer="$(env_value_or_empty "${env_file}" OIDC_ISSUER_URL)"
  case "${issuer}" in
    */realms/*) ;;
    *) die "OIDC_ISSUER_URL must end in /realms/<realm> for self-hosted Keycloak render" ;;
  esac

  keycloak_namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  keycloak_public_base_url="${issuer%%/realms/*}"
  keycloak_realm="${issuer##*/realms/}"
  keycloak_client_id="$(env_value_or_empty "${env_file}" OIDC_CLIENT_ID)"
  keycloak_client_secret="$(env_value_or_empty "${secrets_file}" OIDC_CLIENT_SECRET)"
  keycloak_bootstrap_username="$(env_value_or_empty "${secrets_file}" OIDC_BOOTSTRAP_USERNAME)"
  keycloak_bootstrap_email="$(env_value_or_empty "${env_file}" OIDC_BOOTSTRAP_EMAIL)"
  keycloak_bootstrap_password="$(env_value_or_empty "${secrets_file}" OIDC_BOOTSTRAP_PASSWORD)"
  if ! keycloak_app_public_base_url="$(normalize_public_base_url "$(env_value_or_empty "${env_file}" APP_PUBLIC_BASE_URL)")"; then
    return 1
  fi
  keycloak_ingress_class="$(env_value_or_empty "${env_file}" APP_INGRESS_CLASS)"
  keycloak_traefik_entrypoints="$(env_value_or_empty "${env_file}" APP_INGRESS_TRAEFIK_ENTRYPOINTS)"
  keycloak_tls_secret_name="$(env_value_or_empty "${env_file}" APP_TLS_SECRET_NAME)"
  keycloak_db_user="$(env_value_or_empty "${secrets_file}" KEYCLOAK_DB_USER)"
  keycloak_db_password="$(env_value_or_empty "${secrets_file}" KEYCLOAK_DB_PASSWORD)"
  keycloak_db_database="$(env_value_or_empty "${secrets_file}" KEYCLOAK_DB_DATABASE)"
  keycloak_admin_username="$(env_value_or_empty "${secrets_file}" KEYCLOAK_ADMIN_USERNAME)"
  keycloak_admin_password="$(env_value_or_empty "${secrets_file}" KEYCLOAK_ADMIN_PASSWORD)"

  [[ -n "${keycloak_namespace}" ]] || die "SUBSTRATE_NAMESPACE must be set before rendering Keycloak"
  [[ -n "${keycloak_public_base_url}" ]] || die "OIDC_ISSUER_URL must include a public base URL"
  [[ -n "${keycloak_realm}" ]] || die "OIDC_ISSUER_URL must include a realm"
  [[ "${keycloak_realm}" != */* ]] || die "OIDC_ISSUER_URL realm must not contain /"
  [[ -n "${keycloak_client_id}" ]] || die "OIDC_CLIENT_ID must be set before rendering Keycloak"
  [[ -n "${keycloak_client_secret}" ]] || die "OIDC_CLIENT_SECRET must be set before rendering Keycloak"
  [[ -n "${keycloak_bootstrap_username}" ]] || die "OIDC_BOOTSTRAP_USERNAME must be set before rendering Keycloak"
  [[ -n "${keycloak_bootstrap_email}" ]] || die "OIDC_BOOTSTRAP_EMAIL must be set before rendering Keycloak"
  [[ -n "${keycloak_bootstrap_password}" ]] || die "OIDC_BOOTSTRAP_PASSWORD must be set before rendering Keycloak"
  [[ -n "${keycloak_app_public_base_url}" ]] || die "APP_PUBLIC_BASE_URL must be set before rendering Keycloak"
  [[ "${keycloak_public_base_url}" == https://* ]] || die "self-hosted Keycloak requires an https public base URL"
  [[ "${keycloak_app_public_base_url}" == https://* ]] || die "self-hosted Keycloak requires an https app public base URL"
  [[ -n "${keycloak_ingress_class}" ]] || die "self-hosted Keycloak requires APP_INGRESS_CLASS"
  [[ -n "${keycloak_tls_secret_name}" ]] || die "self-hosted Keycloak requires APP_TLS_SECRET_NAME"
  [[ -n "${keycloak_db_user}" ]] || die "KEYCLOAK_DB_USER must be set before rendering Keycloak"
  [[ -n "${keycloak_db_password}" ]] || die "KEYCLOAK_DB_PASSWORD must be set before rendering Keycloak"
  [[ -n "${keycloak_db_database}" ]] || die "KEYCLOAK_DB_DATABASE must be set before rendering Keycloak"
  [[ -n "${keycloak_admin_username}" ]] || die "KEYCLOAK_ADMIN_USERNAME must be set before rendering Keycloak"
  [[ -n "${keycloak_admin_password}" ]] || die "KEYCLOAK_ADMIN_PASSWORD must be set before rendering Keycloak"
  keycloak_parse_public_base_url "${keycloak_public_base_url}"
}

render_keycloak_secret_manifest() {
  local output="$1"
  local tmp="${output}.tmp"

  : "${keycloak_namespace:?keycloak_prepare_self_hosted_context must be called first}"
  umask 077
  {
    printf 'apiVersion: v1\n'
    printf 'kind: Secret\n'
    printf 'metadata:\n'
    printf '  name: agentsmith-lite-keycloak\n'
    printf '  namespace: %s\n' "${keycloak_namespace}"
    printf 'type: Opaque\n'
    printf 'data:\n'
    printf '  dbUsername: %s\n' "$(keycloak_b64 "${keycloak_db_user}")"
    printf '  dbPassword: %s\n' "$(keycloak_b64 "${keycloak_db_password}")"
    printf '  dbDatabase: %s\n' "$(keycloak_b64 "${keycloak_db_database}")"
    printf '  dbJdbcUrl: %s\n' "$(keycloak_b64 "jdbc:postgresql://postgres.${keycloak_namespace}.svc.cluster.local:5432/${keycloak_db_database}")"
    printf '  adminUsername: %s\n' "$(keycloak_b64 "${keycloak_admin_username}")"
    printf '  adminPassword: %s\n' "$(keycloak_b64 "${keycloak_admin_password}")"
    printf '  oidcRealm: %s\n' "$(keycloak_b64 "${keycloak_realm}")"
    printf '  oidcClientId: %s\n' "$(keycloak_b64 "${keycloak_client_id}")"
    printf '  oidcClientSecret: %s\n' "$(keycloak_b64 "${keycloak_client_secret}")"
    printf '  oidcBootstrapUsername: %s\n' "$(keycloak_b64 "${keycloak_bootstrap_username}")"
    printf '  oidcBootstrapEmail: %s\n' "$(keycloak_b64 "${keycloak_bootstrap_email}")"
    printf '  oidcBootstrapPassword: %s\n' "$(keycloak_b64 "${keycloak_bootstrap_password}")"
    printf '  publicBaseUrl: %s\n' "$(keycloak_b64 "${keycloak_public_base_url}")"
    printf '  appPublicBaseUrl: %s\n' "$(keycloak_b64 "${keycloak_app_public_base_url}")"
  } >"${tmp}"
  chmod 0600 "${tmp}"
  mv "${tmp}" "${output}"
}

render_keycloak_deployment_manifest() {
  local manifest_dir="$1"
  local output="$2"
  local keycloak_image="$3"
  local content ingress_block

  need_file "${manifest_dir}/keycloak.yaml"
  require_digest_pinned_image_ref "keycloak image" "${keycloak_image}"
  : "${keycloak_namespace:?keycloak_prepare_self_hosted_context must be called first}"

  ingress_block="$(keycloak_ingress_manifest_block "${keycloak_ingress_class}" "${keycloak_tls_secret_name}" "${keycloak_traefik_entrypoints}")"
  content="$(<"${manifest_dir}/keycloak.yaml")"
  content="${content//\$\{SUBSTRATE_NAMESPACE\}/${keycloak_namespace}}"
  content="${content//\$\{KEYCLOAK_IMAGE\}/${keycloak_image}}"
  content="${content//\$\{KEYCLOAK_INGRESS_BLOCK\}/${ingress_block}}"
  keycloak_render_template "${manifest_dir}/keycloak.yaml" "${output}" "${content}"
}

render_keycloak_bootstrap_job() {
  local manifest_dir="$1"
  local output="$2"
  local keycloak_image="$3"
  local content

  need_file "${manifest_dir}/bootstrap-job.yaml"
  require_digest_pinned_image_ref "keycloak image" "${keycloak_image}"
  : "${keycloak_namespace:?keycloak_prepare_self_hosted_context must be called first}"

  content="$(<"${manifest_dir}/bootstrap-job.yaml")"
  content="${content//\$\{SUBSTRATE_NAMESPACE\}/${keycloak_namespace}}"
  content="${content//\$\{KEYCLOAK_IMAGE\}/${keycloak_image}}"
  keycloak_render_template "${manifest_dir}/bootstrap-job.yaml" "${output}" "${content}"
}
