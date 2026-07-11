#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"

postgres_parse_error() {
  local label="$1"
  local message="$2"
  printf 'error: %s %s\n' "${label}" "${message}" >&2
  return 1
}

postgres_url_decode() {
  local value="$1"
  local stripped escaped
  stripped="${value//%[0-9A-Fa-f][0-9A-Fa-f]/}"
  if [[ "${stripped}" == *%* ]]; then
    return 1
  fi
  escaped="${value//\\/\\\\}"
  printf '%b' "${escaped//%/\\x}"
}

postgres_parse_url() {
  local url="$1"
  local label="$2"
  local out_prefix="$3"
  local scheme rest no_fragment query authority_path userinfo hostpath raw_user raw_password hostport raw_db
  local user password db host port safe_url lower_query

  if [[ "${url}" == postgresql://* ]]; then
    scheme="postgresql"
    rest="${url#postgresql://}"
  elif [[ "${url}" == postgres://* ]]; then
    scheme="postgres"
    rest="${url#postgres://}"
  else
    postgres_parse_error "${label}" "must start with postgres:// or postgresql://" || return 1
  fi

  no_fragment="${rest%%#*}"
  query=""
  authority_path="${no_fragment}"
  if [[ "${authority_path}" == *\?* ]]; then
    query="?${authority_path#*\?}"
    authority_path="${authority_path%%\?*}"
  fi
  lower_query="${query,,}"
  if [[ "${lower_query}" == *password=* ]]; then
    postgres_parse_error "${label}" "must not put passwords in query parameters" || return 1
  fi

  if [[ "${authority_path}" != *@* ]]; then
    postgres_parse_error "${label}" "must include username and password" || return 1
  fi
  userinfo="${authority_path%@*}"
  hostpath="${authority_path##*@}"
  if [[ "${userinfo}" != *:* ]]; then
    postgres_parse_error "${label}" "must include a password in the URL userinfo" || return 1
  fi
  raw_user="${userinfo%%:*}"
  raw_password="${userinfo#*:}"
  if [[ -z "${raw_user}" || -z "${raw_password}" ]]; then
    postgres_parse_error "${label}" "must include non-empty username and password" || return 1
  fi
  if [[ "${hostpath}" != */* ]]; then
    postgres_parse_error "${label}" "must include a database name" || return 1
  fi
  hostport="${hostpath%%/*}"
  raw_db="${hostpath#*/}"
  if [[ "${raw_db}" == */* ]]; then
    postgres_parse_error "${label}" "must include exactly one database path segment" || return 1
  fi
  if [[ -z "${hostport}" || -z "${raw_db}" ]]; then
    postgres_parse_error "${label}" "must include non-empty host and database" || return 1
  fi

  if ! user="$(postgres_url_decode "${raw_user}")"; then
    postgres_parse_error "${label}" "contains invalid username percent-encoding" || return 1
  fi
  if ! password="$(postgres_url_decode "${raw_password}")"; then
    postgres_parse_error "${label}" "contains invalid password percent-encoding" || return 1
  fi
  if ! db="$(postgres_url_decode "${raw_db}")"; then
    postgres_parse_error "${label}" "contains invalid database percent-encoding" || return 1
  fi

  host="${hostport}"
  port="5432"
  if [[ "${hostport}" == \[*\]* ]]; then
    host="${hostport#\[}"
    host="${host%%\]*}"
    if [[ "${hostport}" == *\]:* ]]; then
      port="${hostport##*\]:}"
    fi
  elif [[ "${hostport}" == *:* ]]; then
    host="${hostport%%:*}"
    port="${hostport##*:}"
  fi
  if [[ -z "${host}" || -z "${port}" || ! "${port}" =~ ^[0-9]+$ ]]; then
    postgres_parse_error "${label}" "must include a valid host and numeric port" || return 1
  fi

  safe_url="${scheme}://${raw_user}@${hostport}/${raw_db}${query}"
  printf -v "${out_prefix}_SCHEME" '%s' "${scheme}"
  printf -v "${out_prefix}_USER" '%s' "${user}"
  printf -v "${out_prefix}_PASSWORD" '%s' "${password}"
  printf -v "${out_prefix}_DATABASE" '%s' "${db}"
  printf -v "${out_prefix}_HOST" '%s' "${host}"
  printf -v "${out_prefix}_PORT" '%s' "${port}"
  printf -v "${out_prefix}_HOSTPORT" '%s' "${host}:${port}"
  printf -v "${out_prefix}_SAFE_URL" '%s' "${safe_url}"
}

postgres_validate_self_hosted_urls() {
  local env_file="$1"
  local secrets_file="$2"
  local namespace app_url meta_url
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  app_url="$(env_value_or_empty "${secrets_file}" POSTGRES_APP_URL)"
  meta_url="$(env_value_or_empty "${secrets_file}" JUICEFS_META_URL)"

  postgres_parse_url "${app_url}" "POSTGRES_APP_URL" "postgres_app" \
    || die "invalid self-hosted POSTGRES_APP_URL"
  postgres_parse_url "${meta_url}" "JUICEFS_META_URL" "postgres_meta" \
    || die "invalid self-hosted JUICEFS_META_URL"
  [[ "${postgres_meta_SCHEME}" == "postgres" ]] || die "JUICEFS_META_URL must start with postgres://"

  if [[ "${postgres_app_HOSTPORT}" != "${postgres_meta_HOSTPORT}" ]]; then
    die "self-hosted Postgres URLs must use the same host"
  fi

  case "${postgres_app_HOST}" in
    postgres|"postgres.${namespace}"|"postgres.${namespace}.svc"|"postgres.${namespace}.svc.cluster.local")
      ;;
    *)
      die "self-hosted POSTGRES_APP_URL host must target the postgres Service in namespace ${namespace}"
      ;;
  esac

  if [[ "${postgres_app_USER}" == "${postgres_meta_USER}" && "${postgres_app_PASSWORD}" != "${postgres_meta_PASSWORD}" ]]; then
    die "self-hosted Postgres URLs cannot use the same username with different passwords"
  fi
}

postgres_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

render_postgres_secret_manifest() {
  local env_file="$1"
  local secrets_file="$2"
  local output="$3"
  local keycloak_user="${4:-}"
  local keycloak_password="${5:-}"
  local keycloak_database="${6:-}"
  local namespace tmp

  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  postgres_validate_self_hosted_urls "${env_file}" "${secrets_file}"
  tmp="${output}.tmp"
  umask 077
  {
    printf 'apiVersion: v1\n'
    printf 'kind: Secret\n'
    printf 'metadata:\n'
    printf '  name: agentsmith-lite-postgres\n'
    printf '  namespace: %s\n' "${namespace}"
    printf 'type: Opaque\n'
    printf 'data:\n'
    printf '  username: %s\n' "$(postgres_base64 "${postgres_app_USER}")"
    printf '  password: %s\n' "$(postgres_base64 "${postgres_app_PASSWORD}")"
    printf '  database: %s\n' "$(postgres_base64 "${postgres_app_DATABASE}")"
    printf '  juicefsUsername: %s\n' "$(postgres_base64 "${postgres_meta_USER}")"
    printf '  juicefsPassword: %s\n' "$(postgres_base64 "${postgres_meta_PASSWORD}")"
    printf '  juicefsDatabase: %s\n' "$(postgres_base64 "${postgres_meta_DATABASE}")"
    if [[ -n "${keycloak_user}" ]]; then
      [[ -n "${keycloak_password}" && -n "${keycloak_database}" ]] \
        || die "Keycloak Postgres credentials must include user, password, and database"
      printf '  keycloakUsername: %s\n' "$(postgres_base64 "${keycloak_user}")"
      printf '  keycloakPassword: %s\n' "$(postgres_base64 "${keycloak_password}")"
      printf '  keycloakDatabase: %s\n' "$(postgres_base64 "${keycloak_database}")"
    fi
  } >"${tmp}"
  chmod 0600 "${tmp}"
  mv "${tmp}" "${output}"
}

postgres_render_template() {
  local input="$1"
  local output="$2"
  local content="$3"
  if grep -Eq '\$\{[A-Z0-9_]+\}' <<<"${content}"; then
    die "Postgres manifest template has unresolved placeholders after rendering: ${input}"
  fi
  printf '%s\n' "${content}" >"${output}"
}

render_postgres_init_job() {
  local env_file="$1"
  local secrets_file="$2"
  local manifest_dir="$3"
  local output="$4"
  local postgres_image="$5"
  local keycloak_user="${6:-}"
  local keycloak_password="${7:-}"
  local keycloak_database="${8:-}"
  local namespace content keycloak_env_block keycloak_required_env_block keycloak_sql_block keycloak_verify_block

  need_file "${manifest_dir}/postgres-init-job.yaml"
  [[ "${postgres_image}" =~ @sha256:[0-9a-f]{64}$ ]] \
    || die "postgres image must be digest-pinned before rendering init Job"

  postgres_validate_self_hosted_urls "${env_file}" "${secrets_file}"
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  [[ -n "${namespace}" ]] || die "SUBSTRATE_NAMESPACE must be set before rendering Postgres init Job"

  keycloak_env_block=""
  keycloak_required_env_block=""
  keycloak_sql_block=""
  keycloak_verify_block=""
  if [[ -n "${keycloak_user}" ]]; then
    [[ -n "${keycloak_password}" && -n "${keycloak_database}" ]] \
      || die "Keycloak Postgres credentials must include user, password, and database"
    keycloak_env_block='            - name: KEYCLOAK_DB_USER
              valueFrom:
                secretKeyRef:
                  name: agentsmith-lite-postgres
                  key: keycloakUsername
            - name: KEYCLOAK_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: agentsmith-lite-postgres
                  key: keycloakPassword
            - name: KEYCLOAK_DB
              valueFrom:
                secretKeyRef:
                  name: agentsmith-lite-postgres
                  key: keycloakDatabase'
    keycloak_required_env_block='              : "${KEYCLOAK_DB_USER:?}"
              : "${KEYCLOAK_DB_PASSWORD:?}"
              : "${KEYCLOAK_DB:?}"'
    keycloak_sql_block="
              SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'keycloak_user', :'keycloak_password')
              WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'keycloak_user')\\gexec
              SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'keycloak_user', :'keycloak_password')\\gexec

              SELECT format('CREATE DATABASE %I OWNER %I', :'keycloak_db', :'keycloak_user')
              WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'keycloak_db')\\gexec
              SELECT format('ALTER DATABASE %I OWNER TO %I', :'keycloak_db', :'keycloak_user')\\gexec
              SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'keycloak_db', :'keycloak_user')\\gexec"
    keycloak_verify_block='
              PGPASSWORD="$KEYCLOAK_DB_PASSWORD" \
                psql -v ON_ERROR_STOP=1 \
                  -h "$POSTGRES_HOST" \
                  -p "$POSTGRES_PORT" \
                  -U "$KEYCLOAK_DB_USER" \
                  -d "$KEYCLOAK_DB" \
                  -Atc '\''select 1'\'' >/dev/null'
  fi

  content="$(<"${manifest_dir}/postgres-init-job.yaml")"
  content="${content//\$\{SUBSTRATE_NAMESPACE\}/${namespace}}"
  content="${content//\$\{POSTGRES_IMAGE\}/${postgres_image}}"
  content="${content//\$\{POSTGRES_HOST\}/${postgres_app_HOST}}"
  content="${content//\$\{POSTGRES_PORT\}/${postgres_app_PORT}}"
  content="${content//\$\{KEYCLOAK_INIT_ENV_BLOCK\}/${keycloak_env_block}}"
  content="${content//\$\{KEYCLOAK_REQUIRED_ENV_BLOCK\}/${keycloak_required_env_block}}"
  content="${content//\$\{KEYCLOAK_SQL_BLOCK\}/${keycloak_sql_block}}"
  content="${content//\$\{KEYCLOAK_VERIFY_BLOCK\}/${keycloak_verify_block}}"
  postgres_render_template "${manifest_dir}/postgres-init-job.yaml" "${output}" "${content}"
}
