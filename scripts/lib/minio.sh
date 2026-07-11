#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"

minio_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

minio_validate_bucket_name() {
  local bucket="$1"
  local length="${#bucket}"
  if (( length < 3 || length > 63 )); then
    die "S3_BUCKET must be between 3 and 63 characters for self-hosted MinIO bootstrap"
  fi
  if [[ ! "${bucket}" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
    die "S3_BUCKET must use lowercase DNS-compatible characters and start/end with a letter or number"
  fi
  case "${bucket}" in
    *..*|*.-*|*-.*)
      die "S3_BUCKET must not contain adjacent dots or dot-hyphen sequences"
      ;;
  esac
  if [[ "${bucket}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "S3_BUCKET must not be formatted as an IP address"
  fi
}

minio_validate_self_hosted_env() {
  local env_file="$1"
  local secrets_file="$2"
  local endpoint bucket access_key secret_key

  endpoint="$(env_value_or_empty "${env_file}" S3_ENDPOINT)"
  bucket="$(env_value_or_empty "${env_file}" S3_BUCKET)"
  access_key="$(env_value_or_empty "${secrets_file}" S3_ACCESS_KEY)"
  secret_key="$(env_value_or_empty "${secrets_file}" S3_SECRET_KEY)"

  [[ -n "${endpoint}" ]] || die "S3_ENDPOINT must be set for self-hosted MinIO bootstrap"
  case "${endpoint}" in
    http://*|https://*)
      ;;
    *)
      die "S3_ENDPOINT must start with http:// or https:// for self-hosted MinIO bootstrap"
      ;;
  esac
  [[ -n "${access_key}" ]] || die "S3_ACCESS_KEY must be set for self-hosted MinIO bootstrap"
  [[ -n "${secret_key}" ]] || die "S3_SECRET_KEY must be set for self-hosted MinIO bootstrap"
  minio_validate_bucket_name "${bucket}"
}

minio_render_template() {
  local input="$1"
  local output="$2"
  local content="$3"
  if grep -Eq '\$\{[A-Z0-9_]+\}' <<<"${content}"; then
    die "MinIO manifest template has unresolved placeholders after rendering"
  fi
  printf '%s\n' "${content}" >"${output}"
}

render_minio_secret_manifest() {
  local env_file="$1"
  local secrets_file="$2"
  local manifest_dir="$3"
  local output="$4"
  local namespace access_key secret_key content tmp

  need_file "${manifest_dir}/secret.example.yaml"
  minio_validate_self_hosted_env "${env_file}" "${secrets_file}"
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  access_key="$(env_value_or_empty "${secrets_file}" S3_ACCESS_KEY)"
  secret_key="$(env_value_or_empty "${secrets_file}" S3_SECRET_KEY)"

  content="$(<"${manifest_dir}/secret.example.yaml")"
  content="${content//\$\{SUBSTRATE_NAMESPACE\}/${namespace}}"
  content="${content//\$\{S3_ACCESS_KEY_B64\}/$(minio_base64 "${access_key}")}"
  content="${content//\$\{S3_SECRET_KEY_B64\}/$(minio_base64 "${secret_key}")}"

  tmp="${output}.tmp"
  umask 077
  minio_render_template "${manifest_dir}/secret.example.yaml" "${tmp}" "${content}"
  chmod 0600 "${tmp}"
  mv "${tmp}" "${output}"
}

render_minio_bucket_init_job() {
  local env_file="$1"
  local manifest_dir="$2"
  local output="$3"
  local minio_client_image="$4"
  local namespace endpoint bucket content

  need_file "${manifest_dir}/bucket-init-job.yaml"
  namespace="$(env_value_or_empty "${env_file}" SUBSTRATE_NAMESPACE)"
  endpoint="$(env_value_or_empty "${env_file}" S3_ENDPOINT)"
  bucket="$(env_value_or_empty "${env_file}" S3_BUCKET)"
  minio_validate_bucket_name "${bucket}"

  [[ "${minio_client_image}" =~ @sha256:[0-9a-f]{64}$ ]] \
    || die "minio-client image must be digest-pinned before rendering bucket init Job"

  content="$(<"${manifest_dir}/bucket-init-job.yaml")"
  content="${content//\$\{SUBSTRATE_NAMESPACE\}/${namespace}}"
  content="${content//\$\{MINIO_CLIENT_IMAGE\}/${minio_client_image}}"
  content="${content//\$\{S3_ENDPOINT\}/${endpoint}}"
  content="${content//\$\{S3_BUCKET\}/${bucket}}"
  minio_render_template "${manifest_dir}/bucket-init-job.yaml" "${output}" "${content}"
}
