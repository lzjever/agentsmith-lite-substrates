#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

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
    /^[[:space:]]*($|#)/ { next }
    /^[A-Za-z0-9_-]+:[[:space:]]*/ {
      line=$0
      split(line, parts, ":")
      section=trim(parts[1])
      value=trim(substr(line, index(line, ":") + 1))
      if (section == wanted) {
        print value
        found=1
      }
      next
    }
    /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      split(line, parts, ":")
      key=trim(parts[1])
      value=trim(substr(line, index(line, ":") + 1))
      full=section "." key
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

validate_config_contract() {
  local config_file="$1"
  need_file "${config_file}"

  local mode provider auth_mode csi_driver distribution
  mode="$(config_required_value "${config_file}" "mode")"
  case "${mode}" in
    self-hosted|existing-cloud) ;;
    *) die "config contract mode must be self-hosted or existing-cloud" ;;
  esac

  if distribution="$(config_raw_value "${config_file}" "kubernetes.distribution" 2>/dev/null)"; then
    [[ "${distribution}" == "k3s" ]] || die "config contract kubernetes.distribution must be k3s"
  fi

  local required_key
  for required_key in \
    kubernetes.namespace \
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
    builtin_admin) ;;
    *) die "OIDC/Keycloak is deferred; AUTH_MODE must be builtin_admin" ;;
  esac

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
  local fallback
  fallback="$(random_secret)"
  printf '%s' "${!env_name:-${fallback}}"
}

write_env_contract_from_config() {
  local config_file="$1"
  local output_dir="$2"
  local install_path="$3"
  local force="${4:-false}"

  need_file "${config_file}"
  validate_config_contract "${config_file}"
  mkdir -p "${output_dir}"

  local mode namespace kubeconfig_path kube_context kubeconfig_output
  mode="$(config_value "${config_file}" "mode" "self-hosted")"
  namespace="$(config_value "${config_file}" "kubernetes.namespace" "agentsmith")"
  kubeconfig_path="$(config_value "${config_file}" "kubernetes.kubeconfigPath" "")"
  kube_context="$(config_value "${config_file}" "kubernetes.context" "")"
  kubeconfig_output="$(config_value "${config_file}" "kubernetes.kubeconfigOutput" "")"

  if [[ -z "${kubeconfig_path}" && -n "${kubeconfig_output}" ]]; then
    kubeconfig_path="${kubeconfig_output}"
  fi
  if [[ -z "${kube_context}" && "${mode}" == "self-hosted" ]]; then
    kube_context="agentsmith-lite"
  fi

  local provider endpoint region bucket force_path_style
  provider="$(config_value "${config_file}" "objectStorage.provider" "minio")"
  endpoint="$(config_value "${config_file}" "objectStorage.endpoint" "")"
  region="$(config_value "${config_file}" "objectStorage.region" "us-east-1")"
  bucket="$(config_value "${config_file}" "objectStorage.bucket" "agentsmith-lite-files")"
  if [[ -z "${endpoint}" ]]; then
    if [[ "${provider}" == "minio" ]]; then
      endpoint="http://minio.${namespace}.svc.cluster.local:9000"
    else
      endpoint="https://s3.${region}.amazonaws.com"
    fi
  fi
  if [[ "${provider}" == "minio" ]]; then
    force_path_style="true"
  else
    force_path_style="$(config_value "${config_file}" "objectStorage.forcePathStyle" "false")"
  fi

  local auth_mode oidc_issuer oidc_client_id public_base_url ingress_class tls_secret registry image_pull_secret
  auth_mode="$(config_value "${config_file}" "auth.mode" "builtin_admin")"
  oidc_issuer=""
  oidc_client_id=""
  public_base_url="$(config_value "${config_file}" "ingress.publicBaseUrl" "http://localhost:3000")"
  ingress_class="$(config_value "${config_file}" "ingress.ingressClass" "")"
  tls_secret="$(config_value "${config_file}" "ingress.tlsSecretName" "")"
  registry="$(config_value "${config_file}" "offline.registry" "")"
  image_pull_secret="$(config_value "${config_file}" "registry.imagePullSecretName" "")"

  local juicefs_volume juicefs_bucket juicefs_secret juicefs_driver juicefs_sc juicefs_pvc juicefs_mount
  juicefs_volume="$(config_value "${config_file}" "juicefs.volumeName" "agentsmith-lite-files")"
  juicefs_bucket="$(config_value "${config_file}" "juicefs.bucket" "s3://${bucket}/agentsmith-lite/")"
  juicefs_secret="$(config_value "${config_file}" "juicefs.secretName" "agentsmith-lite-juicefs")"
  juicefs_driver="$(config_value "${config_file}" "juicefs.csiDriver" "csi.juicefs.com")"
  juicefs_sc="$(config_value "${config_file}" "juicefs.storageClass" "agentsmith-lite-juicefs-rwx")"
  juicefs_pvc="$(config_value "${config_file}" "juicefs.pvcName" "agentsmith-lite-files")"
  juicefs_mount="$(config_value "${config_file}" "juicefs.mountRoot" "/agentsmith-lite")"

  local postgres_app_url app_session_secret juicefs_meta_url s3_access s3_secret admin_password oidc_secret
  oidc_secret=""
  if [[ "${mode}" == "existing-cloud" ]]; then
    local app_url_env meta_url_env access_env secret_env
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
    [[ -n "${s3_access}" ]] || die "existing-cloud requires ${access_env}"
    [[ -n "${s3_secret}" ]] || die "existing-cloud requires ${secret_env}"
  else
    local postgres_password juicefs_password
    postgres_password="$(env_or_generated_secret POSTGRES_PASSWORD)"
    juicefs_password="$(env_or_generated_secret JUICEFS_META_PASSWORD)"
    s3_access="${S3_ACCESS_KEY:-minio$(random_secret | cut -c1-12)}"
    s3_secret="${S3_SECRET_KEY:-$(random_secret)}"
    postgres_app_url="${POSTGRES_APP_URL:-postgresql://agentsmith:${postgres_password}@postgres.${namespace}.svc.cluster.local:5432/agentsmith_lite}"
    juicefs_meta_url="${JUICEFS_META_URL:-postgresql://juicefs:${juicefs_password}@postgres.${namespace}.svc.cluster.local:5432/juicefs_meta}"
  fi
  admin_password="${BUILTIN_ADMIN_INITIAL_PASSWORD:-$(random_secret)}"
  app_session_secret="${APP_SESSION_SECRET:-$(random_secret)}"

  if [[ "${force}" != "true" && ( -e "${output_dir}/substrate.env" || -e "${output_dir}/substrate.secrets.env" ) ]]; then
    die "output env files already exist; rerun with --force to overwrite"
  fi

  cat >"${output_dir}/substrate.env" <<EOF_ENV
SUBSTRATE_SCHEMA_VERSION=agentsmith-lite.substrate.env/v1
KUBECONFIG_PATH=${kubeconfig_path}
KUBE_CONTEXT=${kube_context}
KUBE_NAMESPACE=${namespace}
S3_ENDPOINT=${endpoint}
S3_REGION=${region}
S3_BUCKET=${bucket}
S3_FORCE_PATH_STYLE=${force_path_style}
AUTH_MODE=${auth_mode}
OIDC_ISSUER_URL=${oidc_issuer}
OIDC_CLIENT_ID=${oidc_client_id}
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

  umask 077
  cat >"${output_dir}/substrate.secrets.env" <<EOF_SECRETS
SUBSTRATE_SCHEMA_VERSION=agentsmith-lite.substrate.env/v1
POSTGRES_APP_URL=${postgres_app_url}
APP_SESSION_SECRET=${app_session_secret}
S3_ACCESS_KEY=${s3_access}
S3_SECRET_KEY=${s3_secret}
JUICEFS_META_URL=${juicefs_meta_url}
BUILTIN_ADMIN_INITIAL_PASSWORD=${admin_password}
OIDC_CLIENT_SECRET=${oidc_secret}
EOF_SECRETS
  chmod 0600 "${output_dir}/substrate.secrets.env"

  info "${install_path}: wrote ${output_dir}/substrate.env"
  info "${install_path}: wrote ${output_dir}/substrate.secrets.env with owner-only permissions"
}
