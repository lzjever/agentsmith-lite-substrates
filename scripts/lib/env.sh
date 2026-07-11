#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

SUBSTRATE_ENV_SCHEMA_VERSION="agentsmith-lite.substrate.env/v1"

NON_SECRET_REQUIRED_KEYS=(
  SUBSTRATE_SCHEMA_VERSION
  KUBE_NAMESPACE
  SUBSTRATE_NAMESPACE
  S3_ENDPOINT
  S3_REGION
  S3_BUCKET
  S3_FORCE_PATH_STYLE
  AUTH_MODE
  JUICEFS_VOLUME_NAME
  JUICEFS_BUCKET
  JUICEFS_SECRET_NAME
  JUICEFS_CSI_DRIVER
  JUICEFS_STORAGE_CLASS
  JUICEFS_PVC_NAME
  JUICEFS_MOUNT_ROOT
  APP_PUBLIC_BASE_URL
)

NON_SECRET_ALLOWED_KEYS=(
  "${NON_SECRET_REQUIRED_KEYS[@]}"
  KUBECONFIG_PATH
  KUBE_CONTEXT
  KUBERNETES_SKIP_K3S
  OIDC_ISSUER_URL
  OIDC_CLIENT_ID
  OIDC_BACKCHANNEL_BASE_URL
  OIDC_BOOTSTRAP_EMAIL
  APP_INGRESS_CLASS
  APP_TLS_SECRET_NAME
  REGISTRY_URL
  IMAGE_PULL_SECRET_NAME
)

SECRET_REQUIRED_KEYS=(
  SUBSTRATE_SCHEMA_VERSION
  POSTGRES_APP_URL
  APP_SESSION_SECRET
  S3_ACCESS_KEY
  S3_SECRET_KEY
  JUICEFS_META_URL
  BUILTIN_ADMIN_INITIAL_PASSWORD
  OIDC_CLIENT_SECRET
)

SECRET_ALLOWED_KEYS=(
  "${SECRET_REQUIRED_KEYS[@]}"
  OIDC_BOOTSTRAP_USERNAME
  OIDC_BOOTSTRAP_PASSWORD
  KEYCLOAK_DB_USER
  KEYCLOAK_DB_PASSWORD
  KEYCLOAK_DB_DATABASE
  KEYCLOAK_ADMIN_USERNAME
  KEYCLOAK_ADMIN_PASSWORD
)

contains_key() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

is_secret_key() {
  contains_key "$1" "${SECRET_ALLOWED_KEYS[@]}" && [[ "$1" != "SUBSTRATE_SCHEMA_VERSION" ]]
}

is_allowed_non_secret_key() {
  contains_key "$1" "${NON_SECRET_ALLOWED_KEYS[@]}"
}

is_allowed_secret_file_key() {
  contains_key "$1" "${SECRET_ALLOWED_KEYS[@]}"
}

env_keys() {
  local file="$1"
  awk '
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { next }
      split(line, parts, "=")
      print parts[1]
    }
  ' "${file}"
}

env_value() {
  local file="$1"
  local key="$2"
  awk -v wanted="${key}" '
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      idx=index(line, "=")
      if (idx == 0) { next }
      key=substr(line, 1, idx - 1)
      value=substr(line, idx + 1)
      if (key == wanted) {
        if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
          value=substr(value, 2, length(value) - 2)
        }
        print value
        found=1
      }
    }
    END { if (!found) exit 1 }
  ' "${file}"
}

env_has_key() {
  local file="$1"
  local key="$2"
  env_value "${file}" "${key}" >/dev/null 2>&1
}

env_value_or_empty() {
  local file="$1"
  local key="$2"
  env_value "${file}" "${key}" 2>/dev/null || true
}

validate_env_syntax() {
  local file="$1"
  local label="$2"
  local bad
  bad="$(awk '
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        print NR ":" $0
      }
    }
  ' "${file}")"
  if [[ -n "${bad}" ]]; then
    die "${label} contains invalid KEY=VALUE lines: ${bad}"
  fi
}

check_no_duplicate_env_keys() {
  local file="$1"
  local label="$2"
  local duplicate
  duplicate="$(awk '
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      idx=index(line, "=")
      if (idx == 0) { next }
      key=substr(line, 1, idx - 1)
      if (seen[key]++) {
        print key
        found=1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "${file}" || true)"
  [[ -z "${duplicate}" ]] || die "${label} contains duplicate key ${duplicate}"
}

require_key_present() {
  local file="$1"
  local key="$2"
  local label="$3"
  env_has_key "${file}" "${key}" || die "${label} is missing required key ${key}"
}

require_key_nonempty() {
  local file="$1"
  local key="$2"
  local label="$3"
  require_key_present "${file}" "${key}" "${label}"
  local value
  value="$(env_value_or_empty "${file}" "${key}")"
  [[ -n "${value}" ]] || die "${label} key ${key} must not be empty"
}

require_value_regex() {
  local value="$1"
  local pattern="$2"
  local message="$3"
  if [[ ! "${value}" =~ ${pattern} ]]; then
    die "${message}"
  fi
}

is_kubernetes_rfc1123_label() {
  local value="$1"
  local pattern='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
  [[ "${#value}" -le 63 ]] || return 1
  [[ "${value}" =~ ${pattern} ]]
}

is_kubernetes_dns_subdomain_name() {
  local value="$1"
  local pattern='^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$'
  [[ "${#value}" -le 253 ]] || return 1
  [[ "${value}" =~ ${pattern} ]] || return 1

  local label
  local -a labels
  local IFS=.
  read -r -a labels <<<"${value}"
  for label in "${labels[@]}"; do
    [[ "${#label}" -le 63 ]] || return 1
  done
}

is_s3_bucket_name() {
  local value="$1"
  local bucket_pattern='^[a-z0-9][a-z0-9.-]*[a-z0-9]$'
  local ipv4_pattern='^[0-9]+(\.[0-9]+){3}$'
  [[ "${#value}" -ge 3 && "${#value}" -le 63 ]] || return 1
  [[ "${value}" =~ ${bucket_pattern} ]] || return 1
  [[ "${value}" != *..* ]] || return 1
  [[ "${value}" != *.-* ]] || return 1
  [[ "${value}" != *-.* ]] || return 1
  [[ ! "${value}" =~ ${ipv4_pattern} ]]
}

is_juicefs_bucket_url() {
  local value="$1"
  local pattern='^https?://[^/[:space:]?#]+/[^/[:space:]?#]+/?$'
  [[ "${value}" =~ ${pattern} ]]
}

is_juicefs_meta_url() {
  local value="$1"
  local pattern='^postgres://[^:/@[:space:]?#]+:[^/@[:space:]?#]+@[^/[:space:]?#]+:[0-9]+/[^/[:space:]?#]+$'
  [[ "${value}" =~ ${pattern} ]]
}

is_oidc_issuer_url() {
  local value="$1"
  local pattern='^https?://[^[:space:]?#]+(/[^[:space:]?#]*)?$'
  [[ "${value}" =~ ${pattern} ]]
}

is_oidc_client_id() {
  local value="$1"
  local pattern='^[A-Za-z0-9._:-]+$'
  [[ "${value}" =~ ${pattern} ]]
}

require_env_value_rule() {
  local file="$1"
  local key="$2"
  local rule="$3"
  local validator="$4"
  local value
  value="$(env_value_or_empty "${file}" "${key}")"
  if ! "${validator}" "${value}"; then
    die "${key} must be ${rule}"
  fi
}

check_secret_file_mode() {
  local file="$1"
  local mode
  if ! mode="$(file_mode "${file}")"; then
    warn "could not inspect permissions for ${file}; expected owner-only permissions"
    return 0
  fi

  local normalized="${mode: -3}"
  local group_other="${normalized:1:2}"
  if [[ "${group_other}" != "00" ]]; then
    die "secret env permissions must not allow group/world access: ${file} mode ${mode}"
  fi
  if [[ "${normalized}" != "600" ]]; then
    warn "secret env mode is ${mode}; generated files should be chmod 0600"
  fi
}

check_no_placeholder_values() {
  local file="$1"
  local key value lower
  while IFS= read -r key; do
    value="$(env_value_or_empty "${file}" "${key}")"
    lower="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
    case "${lower}" in
      *'<replace'*|*'replace_me'*|*'changeme'*|*'todo'*|*'<secret>'*)
        die "${file} key ${key} contains a placeholder value"
        ;;
    esac
  done < <(env_keys "${file}")
}

validate_env_contract() {
  local env_file="$1"
  local secrets_file="$2"

  need_file "${env_file}"
  need_file "${secrets_file}"
  validate_env_syntax "${env_file}" "substrate.env"
  validate_env_syntax "${secrets_file}" "substrate.secrets.env"
  check_no_duplicate_env_keys "${env_file}" "substrate.env"
  check_no_duplicate_env_keys "${secrets_file}" "substrate.secrets.env"
  check_secret_file_mode "${secrets_file}"

  local key
  while IFS= read -r key; do
    if is_secret_key "${key}"; then
      die "secret key ${key} is not allowed in non-secret env"
    fi
    if ! is_allowed_non_secret_key "${key}"; then
      die "unknown non-secret env key ${key}"
    fi
  done < <(env_keys "${env_file}")

  while IFS= read -r key; do
    if ! is_allowed_secret_file_key "${key}"; then
      die "substrate.secrets.env may contain only substrate/CSI secret keys; found ${key}"
    fi
  done < <(env_keys "${secrets_file}")

  for key in "${NON_SECRET_REQUIRED_KEYS[@]}"; do
    require_key_nonempty "${env_file}" "${key}" "substrate.env"
  done
  for key in "${SECRET_REQUIRED_KEYS[@]}"; do
    require_key_present "${secrets_file}" "${key}" "substrate.secrets.env"
  done
  require_key_nonempty "${secrets_file}" "POSTGRES_APP_URL" "substrate.secrets.env"
  require_key_nonempty "${secrets_file}" "APP_SESSION_SECRET" "substrate.secrets.env"
  require_key_nonempty "${secrets_file}" "S3_ACCESS_KEY" "substrate.secrets.env"
  require_key_nonempty "${secrets_file}" "S3_SECRET_KEY" "substrate.secrets.env"
  require_key_nonempty "${secrets_file}" "JUICEFS_META_URL" "substrate.secrets.env"

  local env_version secrets_version auth_mode app_session_secret oidc_secret
  env_version="$(env_value_or_empty "${env_file}" "SUBSTRATE_SCHEMA_VERSION")"
  secrets_version="$(env_value_or_empty "${secrets_file}" "SUBSTRATE_SCHEMA_VERSION")"
  [[ "${env_version}" == "${SUBSTRATE_ENV_SCHEMA_VERSION}" ]] || die "unsupported substrate.env schema version ${env_version}"
  [[ "${secrets_version}" == "${SUBSTRATE_ENV_SCHEMA_VERSION}" ]] || die "unsupported substrate.secrets.env schema version ${secrets_version}"

  app_session_secret="$(env_value_or_empty "${secrets_file}" "APP_SESSION_SECRET")"
  [[ "${#app_session_secret}" -ge 32 ]] || die "APP_SESSION_SECRET must be at least 32 characters"

  auth_mode="$(env_value_or_empty "${env_file}" "AUTH_MODE")"
  case "${auth_mode}" in
    builtin_admin)
      require_key_nonempty "${secrets_file}" "BUILTIN_ADMIN_INITIAL_PASSWORD" "substrate.secrets.env"
      [[ -z "$(env_value_or_empty "${env_file}" "OIDC_ISSUER_URL")" ]] \
        || die "OIDC_ISSUER_URL must be empty when AUTH_MODE=builtin_admin"
      [[ -z "$(env_value_or_empty "${env_file}" "OIDC_CLIENT_ID")" ]] \
        || die "OIDC_CLIENT_ID must be empty when AUTH_MODE=builtin_admin"
      [[ -z "$(env_value_or_empty "${env_file}" "OIDC_BACKCHANNEL_BASE_URL")" ]] \
        || die "OIDC_BACKCHANNEL_BASE_URL must be empty when AUTH_MODE=builtin_admin"
      [[ -z "$(env_value_or_empty "${env_file}" "OIDC_BOOTSTRAP_EMAIL")" ]] \
        || die "OIDC_BOOTSTRAP_EMAIL must be empty when AUTH_MODE=builtin_admin"
      oidc_secret="$(env_value_or_empty "${secrets_file}" "OIDC_CLIENT_SECRET")"
      [[ -z "${oidc_secret}" ]] || die "OIDC_CLIENT_SECRET must be empty when AUTH_MODE=builtin_admin"
      [[ -z "$(env_value_or_empty "${secrets_file}" "OIDC_BOOTSTRAP_USERNAME")" ]] \
        || die "OIDC_BOOTSTRAP_USERNAME must be empty when AUTH_MODE=builtin_admin"
      [[ -z "$(env_value_or_empty "${secrets_file}" "OIDC_BOOTSTRAP_PASSWORD")" ]] \
        || die "OIDC_BOOTSTRAP_PASSWORD must be empty when AUTH_MODE=builtin_admin"
      ;;
    oidc)
      require_key_nonempty "${env_file}" "OIDC_ISSUER_URL" "substrate.env"
      require_key_nonempty "${env_file}" "OIDC_CLIENT_ID" "substrate.env"
      require_key_nonempty "${secrets_file}" "OIDC_CLIENT_SECRET" "substrate.secrets.env"
      require_env_value_rule "${env_file}" "OIDC_ISSUER_URL" "an http(s) OIDC issuer URL without query or fragment" is_oidc_issuer_url
      require_env_value_rule "${env_file}" "OIDC_CLIENT_ID" "an OIDC client id made of letters, digits, dot, underscore, colon, or dash" is_oidc_client_id
      if [[ -n "$(env_value_or_empty "${env_file}" "OIDC_BACKCHANNEL_BASE_URL")" ]]; then
        require_env_value_rule "${env_file}" "OIDC_BACKCHANNEL_BASE_URL" "an http(s) OIDC backchannel URL without query or fragment" is_oidc_issuer_url
      fi
      ;;
    *)
      die "AUTH_MODE must be builtin_admin or oidc"
      ;;
  esac

  require_value_regex "$(env_value_or_empty "${secrets_file}" "POSTGRES_APP_URL")" '^postgres(ql)?://' "POSTGRES_APP_URL must start with postgres:// or postgresql://"
  require_env_value_rule "${secrets_file}" "JUICEFS_META_URL" "postgres://user:password@host:port/db" is_juicefs_meta_url
  require_value_regex "$(env_value_or_empty "${env_file}" "S3_ENDPOINT")" '^https?://' "S3_ENDPOINT must start with http:// or https://"
  require_value_regex "$(env_value_or_empty "${env_file}" "S3_FORCE_PATH_STYLE")" '^(true|false)$' "S3_FORCE_PATH_STYLE must be true or false"
  if env_has_key "${env_file}" "KUBERNETES_SKIP_K3S"; then
    require_value_regex "$(env_value_or_empty "${env_file}" "KUBERNETES_SKIP_K3S")" '^(true|false)$' "KUBERNETES_SKIP_K3S must be true or false"
  fi
  require_env_value_rule "${env_file}" "JUICEFS_BUCKET" "a full http(s) bucket URL" is_juicefs_bucket_url
  require_value_regex "$(env_value_or_empty "${env_file}" "JUICEFS_MOUNT_ROOT")" '^/' "JUICEFS_MOUNT_ROOT must be an absolute path"
  require_value_regex "$(env_value_or_empty "${env_file}" "APP_PUBLIC_BASE_URL")" '^https?://' "APP_PUBLIC_BASE_URL must start with http:// or https://"
  [[ "$(env_value_or_empty "${env_file}" "JUICEFS_CSI_DRIVER")" == "csi.juicefs.com" ]] || die "JUICEFS_CSI_DRIVER must be csi.juicefs.com"
  require_env_value_rule "${env_file}" "KUBE_NAMESPACE" "a Kubernetes RFC1123 DNS label" is_kubernetes_rfc1123_label
  require_env_value_rule "${env_file}" "SUBSTRATE_NAMESPACE" "a Kubernetes RFC1123 DNS label" is_kubernetes_rfc1123_label
  require_env_value_rule "${env_file}" "JUICEFS_SECRET_NAME" "a Kubernetes RFC1123 DNS label" is_kubernetes_rfc1123_label
  require_env_value_rule "${env_file}" "JUICEFS_PVC_NAME" "a Kubernetes RFC1123 DNS label" is_kubernetes_rfc1123_label
  require_env_value_rule "${env_file}" "JUICEFS_STORAGE_CLASS" "a Kubernetes DNS subdomain name" is_kubernetes_dns_subdomain_name
  require_env_value_rule "${env_file}" "S3_BUCKET" "an S3 bucket name" is_s3_bucket_name

  check_no_placeholder_values "${env_file}"
  check_no_placeholder_values "${secrets_file}"

  info "secret boundary: app deploy may render only product-secret subset; S3_ACCESS_KEY, S3_SECRET_KEY, JUICEFS_META_URL, and KEYCLOAK_* are substrate scoped"
  for key in POSTGRES_APP_URL APP_SESSION_SECRET S3_ACCESS_KEY S3_SECRET_KEY JUICEFS_META_URL BUILTIN_ADMIN_INITIAL_PASSWORD OIDC_CLIENT_SECRET OIDC_BOOTSTRAP_USERNAME OIDC_BOOTSTRAP_PASSWORD KEYCLOAK_DB_USER KEYCLOAK_DB_PASSWORD KEYCLOAK_DB_DATABASE KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD; do
    if env_has_key "${secrets_file}" "${key}"; then
      local value
      value="$(env_value_or_empty "${secrets_file}" "${key}")"
      if [[ -n "${value}" ]]; then
        info "secret ${key} fingerprint=$(fingerprint_value "${value}")"
      else
        info "secret ${key} fingerprint=empty"
      fi
    fi
  done
  info "validated substrate env contract: env=${env_file} secrets=${secrets_file}"
}
