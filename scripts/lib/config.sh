#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"

config_raw_value() {
  local file="$1"
  local path="$2"
  awk -v wanted="${path}" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    function joined_path(level,    i, full) {
      full=keys[0]
      for (i=1; i<=level; i++) {
        full=full "." keys[i]
      }
      return full
    }
    /^[[:space:]]*($|#)/ { next }
    /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*/ {
      line=$0
      match(line, /^[[:space:]]*/)
      indent=RLENGTH
      level=int(indent / 2)
      sub(/^[[:space:]]+/, "", line)
      split(line, parts, ":")
      keys[level]=trim(parts[1])
      value=trim(substr(line, index(line, ":") + 1))
      for (i=level + 1; i<20; i++) {
        delete keys[i]
      }
      full=joined_path(level)
      if (full == wanted) {
        print value
        found=1
      }
    }
    END { if (!found) exit 1 }
  ' "${file}"
}

config_value() {
  local file="$1"
  local path="$2"
  local default="${3:-}"
  local found
  found="$(config_raw_value "${file}" "${path}" 2>/dev/null || true)"
  if [[ -n "${found}" ]]; then
    printf '%s' "${found}"
  else
    printf '%s' "${default}"
  fi
}

config_required_value() {
  local file="$1"
  local path="$2"
  local value
  if ! value="$(config_raw_value "${file}" "${path}" 2>/dev/null)"; then
    die "config contract requires ${path}"
  fi
  [[ -n "${value}" ]] || die "config contract requires non-empty ${path}"
  printf '%s' "${value}"
}

config_absolute_path() {
  local config_file="$1"
  local path="$2"
  local config_dir component normalized_path
  local -a path_parts normalized_parts

  [[ -n "${path}" ]] || return 0
  if [[ "${path}" != /* ]]; then
    config_dir="$(cd "$(dirname "${config_file}")" && pwd -P)"
    path="${config_dir}/${path}"
  fi

  IFS=/ read -r -a path_parts <<<"${path}"
  for component in "${path_parts[@]}"; do
    case "${component}" in
      ''|.) ;;
      ..)
        if [[ ${#normalized_parts[@]} -gt 0 ]]; then
          unset 'normalized_parts[${#normalized_parts[@]} - 1]'
        fi
        ;;
      *) normalized_parts+=("${component}") ;;
    esac
  done

  if [[ ${#normalized_parts[@]} -eq 0 ]]; then
    printf '/'
  else
    normalized_path="$(IFS=/; printf '%s' "${normalized_parts[*]}")"
    printf '/%s' "${normalized_path}"
  fi
}

validate_config_contract() {
  local config_file="$1"
  need_file "${config_file}"

  local mode provider auth_mode csi_driver distribution skip_k3s kubeconfig_path
  mode="$(config_required_value "${config_file}" "mode")"
  case "${mode}" in
    self-hosted|existing-cloud) ;;
    *) die "config contract mode must be self-hosted or existing-cloud" ;;
  esac

  if distribution="$(config_raw_value "${config_file}" "kubernetes.distribution" 2>/dev/null)"; then
    [[ "${distribution}" == "k3s" ]] || die "config contract kubernetes.distribution must be k3s"
  fi

  skip_k3s="$(config_value "${config_file}" "kubernetes.skipK3s" "false")"
  case "${skip_k3s}" in
    true|false) ;;
    *) die "config contract kubernetes.skipK3s must be true or false" ;;
  esac
  if [[ "${mode}" == "self-hosted" && "${skip_k3s}" == "true" ]]; then
    kubeconfig_path="$(config_required_value "${config_file}" "kubernetes.kubeconfigPath")"
    kubeconfig_path="$(config_absolute_path "${config_file}" "${kubeconfig_path}")"
    [[ -r "${kubeconfig_path}" ]] || die "config contract kubernetes.kubeconfigPath must be readable when kubernetes.skipK3s=true"
  fi

  local required_key
  for required_key in \
    kubernetes.appNamespace \
    kubernetes.substrateNamespace \
    objectStorage.provider \
    objectStorage.bucket \
    juicefs.storageClass \
    juicefs.pvcName \
    auth.mode \
    ingress.publicBaseUrl
  do
    config_required_value "${config_file}" "${required_key}" >/dev/null
  done

  provider="$(config_required_value "${config_file}" "objectStorage.provider")"
  case "${provider}" in
    minio|s3) ;;
    *) die "config contract objectStorage.provider must be minio or s3" ;;
  esac

  auth_mode="$(config_required_value "${config_file}" "auth.mode")"
  case "${auth_mode}" in
    builtin_admin|oidc) ;;
    *) die "config contract auth.mode must be builtin_admin or oidc" ;;
  esac

  if [[ "${auth_mode}" == "oidc" && "${mode}" == "self-hosted" ]]; then
    for required_key in \
      auth.realm \
      auth.clientId \
      auth.keycloak.publicBaseUrl
    do
      config_required_value "${config_file}" "${required_key}" >/dev/null
    done
  fi

  if csi_driver="$(config_raw_value "${config_file}" "juicefs.csiDriver" 2>/dev/null)"; then
    [[ "${csi_driver}" == "csi.juicefs.com" ]] || die "config contract juicefs.csiDriver must be csi.juicefs.com"
  fi

  if [[ "${mode}" == "existing-cloud" ]]; then
    for required_key in \
      postgres.appUrlFromEnv \
      postgres.juicefsMetaUrlFromEnv \
      objectStorage.accessKeyFromEnv \
      objectStorage.secretKeyFromEnv
    do
      config_required_value "${config_file}" "${required_key}" >/dev/null
    done
  fi
}

env_or_generated_secret() {
  local env_name="$1"
  if [[ -n "${!env_name:-}" ]]; then
    printf '%s' "${!env_name}"
  else
    random_secret
  fi
}

env_or_existing_secret() {
  local env_name="$1"
  local existing_secrets_file="${2:-}"
  if [[ -n "${!env_name:-}" ]]; then
    printf '%s' "${!env_name}"
    return 0
  fi
  if [[ -n "${existing_secrets_file}" ]] && env_has_key "${existing_secrets_file}" "${env_name}"; then
    env_value_or_empty "${existing_secrets_file}" "${env_name}"
    return 0
  fi
  return 1
}

env_or_existing_nonempty_secret() {
  local env_name="$1"
  local existing_secrets_file="${2:-}"
  local value
  if [[ -n "${!env_name:-}" ]]; then
    printf '%s' "${!env_name}"
    return 0
  fi
  if [[ -n "${existing_secrets_file}" ]] && env_has_key "${existing_secrets_file}" "${env_name}"; then
    value="$(env_value_or_empty "${existing_secrets_file}" "${env_name}")"
    if [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
  fi
  return 1
}

write_app_overlay_contract() {
  local output_dir="$1"
  local namespace="$2"
  local existing_app_secrets_file="${3:-}"
  local install_path="$4"
  local oidc_bootstrap_email="${5:-}"
  local app_env_file="${output_dir}/app.env"
  local app_secrets_file="${output_dir}/app.secrets.env"
  local local_provider_api_key old_umask

  if ! local_provider_api_key="$(env_or_existing_nonempty_secret AGENTSMITH_LITE_MODEL_API_KEY_LOCAL "${existing_app_secrets_file}")"; then
    local_provider_api_key="$(random_secret)"
  fi

  cat >"${app_env_file}" <<EOF_APP_ENV
AGENTSMITH_LITE_MODEL_BASE_URL_LOCAL=https://agentsmith-lite-local-openai.${namespace}.svc.cluster.local/v1
AGENTSMITH_LITE_MODEL_CA_CONFIG_MAP=agentsmith-lite-local-openai-ca
AGENTSMITH_LITE_MODEL_CA_CONFIG_KEY=ca.crt
AGENTSMITH_LITE_SANDBOX_MODE=live
OIDC_ADMIN_EMAILS=${oidc_bootstrap_email}
EOF_APP_ENV

  old_umask="$(umask)"
  umask 077
  cat >"${app_secrets_file}" <<EOF_APP_SECRETS
AGENTSMITH_LITE_MODEL_API_KEY_LOCAL=${local_provider_api_key}
EOF_APP_SECRETS
  umask "${old_umask}"
  chmod 0600 "${app_secrets_file}"

  info "${install_path}: wrote ${app_env_file}"
  info "${install_path}: wrote ${app_secrets_file} with owner-only permissions"
}

write_env_contract_from_config() {
  local config_file="$1"
  local output_dir="$2"
  local install_path="$3"
  local force="${4:-false}"

  need_file "${config_file}"
  validate_config_contract "${config_file}"
  mkdir -p "${output_dir}"

  local mode app_namespace substrate_namespace kubeconfig_path kube_context kubeconfig_output skip_k3s
  mode="$(config_value "${config_file}" "mode" "self-hosted")"
  local output_env_file output_secrets_file output_app_env_file output_app_secrets_file
  local reuse_self_hosted_secrets_file reuse_self_hosted_app_secrets_file
  output_env_file="${output_dir}/substrate.env"
  output_secrets_file="${output_dir}/substrate.secrets.env"
  output_app_env_file="${output_dir}/app.env"
  output_app_secrets_file="${output_dir}/app.secrets.env"
  reuse_self_hosted_secrets_file=""
  reuse_self_hosted_app_secrets_file=""

  if [[ "${mode}" == "self-hosted" ]]; then
    if [[ "${force}" != "true" && ( -e "${output_env_file}" || -e "${output_secrets_file}" || -e "${output_app_env_file}" || -e "${output_app_secrets_file}" ) ]]; then
      die "output env files already exist; rerun with --force to overwrite"
    fi
    if [[ "${force}" == "true" && ( -e "${output_env_file}" || -e "${output_secrets_file}" ) ]]; then
      if [[ ! -f "${output_env_file}" || ! -f "${output_secrets_file}" ]]; then
        die "self-hosted output env files are incomplete; restore both substrate.env and substrate.secrets.env or clear local substrate state before reinstalling"
      fi
      local validation_output
      if ! validation_output="$(validate_env_contract "${output_env_file}" "${output_secrets_file}" 2>&1)"; then
        die "existing self-hosted output env files do not validate; restore the original output or clear local substrate state before reinstalling: ${validation_output}"
      fi
      reuse_self_hosted_secrets_file="${output_secrets_file}"
    fi
    if [[ "${force}" == "true" && -f "${output_app_secrets_file}" ]]; then
      check_secret_file_mode "${output_app_secrets_file}"
      reuse_self_hosted_app_secrets_file="${output_app_secrets_file}"
    fi
  elif [[ "${force}" != "true" && ( -e "${output_env_file}" || -e "${output_secrets_file}" ) ]]; then
    die "output env files already exist; rerun with --force to overwrite"
  fi

  app_namespace="$(config_required_value "${config_file}" "kubernetes.appNamespace")"
  substrate_namespace="$(config_required_value "${config_file}" "kubernetes.substrateNamespace")"
  [[ "${app_namespace}" != "${substrate_namespace}" ]] \
    || die "config contract kubernetes.appNamespace and kubernetes.substrateNamespace must differ"
  kubeconfig_path="$(config_value "${config_file}" "kubernetes.kubeconfigPath" "")"
  kube_context="$(config_value "${config_file}" "kubernetes.context" "")"
  kubeconfig_output="$(config_value "${config_file}" "kubernetes.kubeconfigOutput" "")"
  skip_k3s="$(config_value "${config_file}" "kubernetes.skipK3s" "false")"

  kubeconfig_path="$(config_absolute_path "${config_file}" "${kubeconfig_path}")"
  kubeconfig_output="$(config_absolute_path "${config_file}" "${kubeconfig_output}")"

  if [[ -z "${kubeconfig_path}" && -n "${kubeconfig_output}" ]]; then
    kubeconfig_path="${kubeconfig_output}"
  fi
  if [[ -z "${kube_context}" && "${mode}" == "self-hosted" && "${skip_k3s}" == "false" ]]; then
    kube_context="default"
  fi
  local provider endpoint region bucket force_path_style
  provider="$(config_value "${config_file}" "objectStorage.provider" "minio")"
  endpoint="$(config_value "${config_file}" "objectStorage.endpoint" "")"
  region="$(config_value "${config_file}" "objectStorage.region" "us-east-1")"
  bucket="$(config_value "${config_file}" "objectStorage.bucket" "agentsmith-lite-files")"
  if [[ -z "${endpoint}" ]]; then
    if [[ "${provider}" == "minio" ]]; then
      endpoint="http://minio.${substrate_namespace}.svc.cluster.local:9000"
    else
      endpoint="https://s3.${region}.amazonaws.com"
    fi
  fi
  if [[ "${provider}" == "minio" ]]; then
    force_path_style="true"
  else
    force_path_style="$(config_value "${config_file}" "objectStorage.forcePathStyle" "false")"
  fi

  local auth_mode oidc_issuer oidc_client_id oidc_backchannel_base_url public_base_url ingress_class tls_secret registry image_pull_secret
  auth_mode="$(config_value "${config_file}" "auth.mode" "builtin_admin")"
  oidc_issuer=""
  oidc_client_id=""
  oidc_backchannel_base_url=""
  public_base_url="$(config_value "${config_file}" "ingress.publicBaseUrl" "http://localhost:3000")"
  if ! public_base_url="$(normalize_public_base_url "${public_base_url}")"; then
    return 1
  fi
  ingress_class="$(config_value "${config_file}" "ingress.ingressClass" "")"
  tls_secret="$(config_value "${config_file}" "ingress.tlsSecretName" "")"
  registry="$(config_value "${config_file}" "offline.registry" "")"
  image_pull_secret="$(config_value "${config_file}" "registry.imagePullSecretName" "")"

  local juicefs_volume juicefs_bucket juicefs_secret juicefs_driver juicefs_sc juicefs_pvc juicefs_mount
  juicefs_volume="$(config_value "${config_file}" "juicefs.volumeName" "agentsmith-lite-files")"
  if juicefs_bucket="$(config_raw_value "${config_file}" "juicefs.bucket" 2>/dev/null)"; then
    [[ -n "${juicefs_bucket}" ]] || die "config contract requires non-empty juicefs.bucket"
  else
    juicefs_bucket="${endpoint%/}/${bucket}"
  fi
  if ! is_juicefs_bucket_url "${juicefs_bucket}"; then
    die "config contract juicefs.bucket must be a full http(s) bucket URL"
  fi
  juicefs_secret="$(config_value "${config_file}" "juicefs.secretName" "agentsmith-lite-juicefs")"
  juicefs_driver="$(config_value "${config_file}" "juicefs.csiDriver" "csi.juicefs.com")"
  juicefs_sc="$(config_value "${config_file}" "juicefs.storageClass" "agentsmith-lite-juicefs-rwx")"
  juicefs_pvc="$(config_value "${config_file}" "juicefs.pvcName" "agentsmith-lite-files")"
  juicefs_mount="$(config_value "${config_file}" "juicefs.mountRoot" "/agentsmith-lite")"

  local postgres_app_url app_session_secret juicefs_meta_url s3_access s3_secret admin_password oidc_secret oidc_bootstrap_username oidc_bootstrap_email oidc_bootstrap_password
  local keycloak_db_user keycloak_db_password keycloak_db_database keycloak_admin_username keycloak_admin_password
  oidc_secret=""
  oidc_bootstrap_username=""
  oidc_bootstrap_email=""
  oidc_bootstrap_password=""
  keycloak_db_user=""
  keycloak_db_password=""
  keycloak_db_database=""
  keycloak_admin_username=""
  keycloak_admin_password=""
  if [[ "${mode}" == "existing-cloud" ]]; then
    local app_url_env meta_url_env access_env secret_env oidc_issuer_env oidc_client_id_env oidc_client_secret_env oidc_backchannel_env
    app_url_env="$(config_value "${config_file}" "postgres.appUrlFromEnv" "POSTGRES_APP_URL")"
    meta_url_env="$(config_value "${config_file}" "postgres.juicefsMetaUrlFromEnv" "JUICEFS_META_URL")"
    access_env="$(config_value "${config_file}" "objectStorage.accessKeyFromEnv" "S3_ACCESS_KEY")"
    secret_env="$(config_value "${config_file}" "objectStorage.secretKeyFromEnv" "S3_SECRET_KEY")"
    postgres_app_url="${!app_url_env:-}"
    juicefs_meta_url="${!meta_url_env:-}"
    s3_access="${!access_env:-}"
    s3_secret="${!secret_env:-}"
    [[ -n "${postgres_app_url}" ]] || die "existing-cloud requires ${app_url_env}"
    [[ -n "${juicefs_meta_url}" ]] || die "existing-cloud requires ${meta_url_env}"
    [[ "${juicefs_meta_url}" == postgres://* ]] || die "JUICEFS_META_URL must start with postgres://"
    is_juicefs_meta_url "${juicefs_meta_url}" || die "JUICEFS_META_URL must be postgres://user:password@host:port/db"
    [[ -n "${s3_access}" ]] || die "existing-cloud requires ${access_env}"
    [[ -n "${s3_secret}" ]] || die "existing-cloud requires ${secret_env}"
    if [[ "${auth_mode}" == "oidc" ]]; then
      oidc_issuer_env="$(config_value "${config_file}" "auth.issuerUrlFromEnv" "OIDC_ISSUER_URL")"
      oidc_client_id_env="$(config_value "${config_file}" "auth.clientIdFromEnv" "OIDC_CLIENT_ID")"
      oidc_client_secret_env="$(config_value "${config_file}" "auth.clientSecretFromEnv" "OIDC_CLIENT_SECRET")"
      oidc_backchannel_env="$(config_value "${config_file}" "auth.backchannelBaseUrlFromEnv" "OIDC_BACKCHANNEL_BASE_URL")"
      oidc_issuer="${!oidc_issuer_env:-}"
      oidc_client_id="${!oidc_client_id_env:-}"
      oidc_secret="${!oidc_client_secret_env:-}"
      oidc_backchannel_base_url="${!oidc_backchannel_env:-}"
      [[ -n "${oidc_issuer}" ]] || die "existing-cloud OIDC requires ${oidc_issuer_env}"
      [[ -n "${oidc_client_id}" ]] || die "existing-cloud OIDC requires ${oidc_client_id_env}"
      [[ -n "${oidc_secret}" ]] || die "existing-cloud OIDC requires ${oidc_client_secret_env}"
    fi
  else
    local postgres_password juicefs_password
    if ! postgres_app_url="$(env_or_existing_secret POSTGRES_APP_URL "${reuse_self_hosted_secrets_file}")"; then
      postgres_password="$(env_or_generated_secret POSTGRES_PASSWORD)"
      postgres_app_url="postgresql://agentsmith:${postgres_password}@postgres.${substrate_namespace}.svc.cluster.local:5432/agentsmith_lite"
    fi
    if ! juicefs_meta_url="$(env_or_existing_secret JUICEFS_META_URL "${reuse_self_hosted_secrets_file}")"; then
      juicefs_password="$(env_or_generated_secret JUICEFS_META_PASSWORD)"
      juicefs_meta_url="postgres://juicefs:${juicefs_password}@postgres.${substrate_namespace}.svc.cluster.local:5432/juicefs_meta"
    fi
    if ! s3_access="$(env_or_existing_secret S3_ACCESS_KEY "${reuse_self_hosted_secrets_file}")"; then
      s3_access="minio$(random_secret | cut -c1-12)"
    fi
    if ! s3_secret="$(env_or_existing_secret S3_SECRET_KEY "${reuse_self_hosted_secrets_file}")"; then
      s3_secret="$(random_secret)"
    fi
    if [[ "${auth_mode}" == "oidc" ]]; then
      local auth_realm auth_client_id keycloak_public_base
      auth_realm="$(config_required_value "${config_file}" "auth.realm")"
      auth_client_id="$(config_required_value "${config_file}" "auth.clientId")"
      keycloak_public_base="$(config_required_value "${config_file}" "auth.keycloak.publicBaseUrl")"
      keycloak_public_base="${keycloak_public_base%/}"
      [[ "${public_base_url}" == https://* ]] || die "self-hosted OIDC requires ingress.publicBaseUrl to use https://"
      [[ "${keycloak_public_base}" == https://* ]] || die "self-hosted OIDC requires auth.keycloak.publicBaseUrl to use https://"
      [[ -n "${ingress_class}" ]] || die "self-hosted OIDC requires ingress.ingressClass"
      [[ -n "${tls_secret}" ]] || die "self-hosted OIDC requires ingress.tlsSecretName"
      oidc_issuer="${keycloak_public_base}/realms/${auth_realm}"
      oidc_client_id="${auth_client_id}"
      oidc_backchannel_base_url="http://keycloak.${substrate_namespace}.svc.cluster.local:8080/realms/${auth_realm}"
      if ! oidc_secret="$(env_or_existing_secret OIDC_CLIENT_SECRET "${reuse_self_hosted_secrets_file}")"; then
        oidc_secret="$(random_secret)"
      fi
      if ! oidc_bootstrap_username="$(env_or_existing_secret OIDC_BOOTSTRAP_USERNAME "${reuse_self_hosted_secrets_file}")"; then
        oidc_bootstrap_username="$(config_value "${config_file}" "auth.bootstrapUsername" "agentsmith-local")"
      fi
      oidc_bootstrap_email="$(config_value "${config_file}" "auth.bootstrapEmail" "bootstrap@agentsmith.localhost")"
      if ! oidc_bootstrap_password="$(env_or_existing_secret OIDC_BOOTSTRAP_PASSWORD "${reuse_self_hosted_secrets_file}")"; then
        oidc_bootstrap_password="$(random_secret)"
      fi
      if ! keycloak_db_user="$(env_or_existing_nonempty_secret KEYCLOAK_DB_USER "${reuse_self_hosted_secrets_file}")"; then
        keycloak_db_user="keycloak"
      fi
      if ! keycloak_db_password="$(env_or_existing_nonempty_secret KEYCLOAK_DB_PASSWORD "${reuse_self_hosted_secrets_file}")"; then
        keycloak_db_password="$(random_secret)"
      fi
      if ! keycloak_db_database="$(env_or_existing_nonempty_secret KEYCLOAK_DB_DATABASE "${reuse_self_hosted_secrets_file}")"; then
        keycloak_db_database="keycloak"
      fi
      if ! keycloak_admin_username="$(env_or_existing_nonempty_secret KEYCLOAK_ADMIN_USERNAME "${reuse_self_hosted_secrets_file}")"; then
        keycloak_admin_username="admin"
      fi
      if ! keycloak_admin_password="$(env_or_existing_nonempty_secret KEYCLOAK_ADMIN_PASSWORD "${reuse_self_hosted_secrets_file}")"; then
        keycloak_admin_password="$(random_secret)"
      fi
    fi
  fi
  if [[ "${auth_mode}" == "builtin_admin" ]]; then
    if ! admin_password="$(env_or_existing_secret BUILTIN_ADMIN_INITIAL_PASSWORD "${reuse_self_hosted_secrets_file}")"; then
      admin_password="$(random_secret)"
    fi
  else
    if ! admin_password="$(env_or_existing_secret BUILTIN_ADMIN_INITIAL_PASSWORD "${reuse_self_hosted_secrets_file}")"; then
      admin_password=""
    fi
  fi
  if ! app_session_secret="$(env_or_existing_secret APP_SESSION_SECRET "${reuse_self_hosted_secrets_file}")"; then
    app_session_secret="$(random_secret)"
  fi

  cat >"${output_env_file}" <<EOF_ENV
SUBSTRATE_SCHEMA_VERSION=agentsmith-lite.substrate.env/v1
KUBECONFIG_PATH=${kubeconfig_path}
KUBE_CONTEXT=${kube_context}
KUBERNETES_SKIP_K3S=${skip_k3s}
KUBE_NAMESPACE=${app_namespace}
SUBSTRATE_NAMESPACE=${substrate_namespace}
S3_ENDPOINT=${endpoint}
S3_REGION=${region}
S3_BUCKET=${bucket}
S3_FORCE_PATH_STYLE=${force_path_style}
AUTH_MODE=${auth_mode}
OIDC_ISSUER_URL=${oidc_issuer}
OIDC_CLIENT_ID=${oidc_client_id}
OIDC_BACKCHANNEL_BASE_URL=${oidc_backchannel_base_url}
OIDC_BOOTSTRAP_EMAIL=${oidc_bootstrap_email}
JUICEFS_VOLUME_NAME=${juicefs_volume}
JUICEFS_BUCKET=${juicefs_bucket}
JUICEFS_SECRET_NAME=${juicefs_secret}
JUICEFS_CSI_DRIVER=${juicefs_driver}
JUICEFS_STORAGE_CLASS=${juicefs_sc}
JUICEFS_PVC_NAME=${juicefs_pvc}
JUICEFS_MOUNT_ROOT=${juicefs_mount}
APP_PUBLIC_BASE_URL=${public_base_url}
APP_INGRESS_CLASS=${ingress_class}
APP_TLS_SECRET_NAME=${tls_secret}
REGISTRY_URL=${registry}
IMAGE_PULL_SECRET_NAME=${image_pull_secret}
EOF_ENV

  local old_umask
  old_umask="$(umask)"
  umask 077
  cat >"${output_secrets_file}" <<EOF_SECRETS
SUBSTRATE_SCHEMA_VERSION=agentsmith-lite.substrate.env/v1
POSTGRES_APP_URL=${postgres_app_url}
APP_SESSION_SECRET=${app_session_secret}
S3_ACCESS_KEY=${s3_access}
S3_SECRET_KEY=${s3_secret}
JUICEFS_META_URL=${juicefs_meta_url}
BUILTIN_ADMIN_INITIAL_PASSWORD=${admin_password}
OIDC_CLIENT_SECRET=${oidc_secret}
OIDC_BOOTSTRAP_USERNAME=${oidc_bootstrap_username}
OIDC_BOOTSTRAP_PASSWORD=${oidc_bootstrap_password}
KEYCLOAK_DB_USER=${keycloak_db_user}
KEYCLOAK_DB_PASSWORD=${keycloak_db_password}
KEYCLOAK_DB_DATABASE=${keycloak_db_database}
KEYCLOAK_ADMIN_USERNAME=${keycloak_admin_username}
KEYCLOAK_ADMIN_PASSWORD=${keycloak_admin_password}
EOF_SECRETS
  umask "${old_umask}"
  chmod 0600 "${output_secrets_file}"

  info "${install_path}: wrote ${output_env_file}"
  info "${install_path}: wrote ${output_secrets_file} with owner-only permissions"
  if [[ "${mode}" == "self-hosted" ]]; then
    write_app_overlay_contract "${output_dir}" "${app_namespace}" "${reuse_self_hosted_app_secrets_file}" "${install_path}" "${oidc_bootstrap_email}"
  fi
}
