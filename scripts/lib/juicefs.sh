#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_LIB_DIR}/env.sh"

render_env_template() {
  local env_file="$1"
  local secrets_file="$2"
  local input="$3"
  local output="$4"
  local content key value
  content="$(<"${input}")"
  for key in \
    KUBE_NAMESPACE \
    JUICEFS_VOLUME_NAME \
    JUICEFS_BUCKET \
    JUICEFS_SECRET_NAME \
    JUICEFS_CSI_DRIVER \
    JUICEFS_STORAGE_CLASS \
    JUICEFS_PVC_NAME \
    JUICEFS_META_URL \
    S3_ACCESS_KEY \
    S3_SECRET_KEY; do
    value="$(env_value_or_empty "${env_file}" "${key}")"
    if [[ -z "${value}" ]]; then
      value="$(env_value_or_empty "${secrets_file}" "${key}")"
    fi
    content="${content//\$\{${key}\}/${value}}"
  done
  if grep -Eq '\$\{[A-Z0-9_]+\}' <<<"${content}"; then
    die "manifest template has unresolved placeholders after rendering"
  fi
  printf '%s\n' "${content}" >"${output}"
}

render_juicefs_contract() {
  local env_file="$1"
  local secrets_file="$2"
  local manifest_dir="$3"
  local output_dir="$4"

  need_dir "${manifest_dir}"
  need_file "${manifest_dir}/secret.example.yaml"
  need_file "${manifest_dir}/storageclass-pvc.yaml"
  mkdir -p "${output_dir}"

  umask 077
  render_env_template "${env_file}" "${secrets_file}" "${manifest_dir}/secret.example.yaml" "${output_dir}/juicefs-secret.yaml"
  chmod 0600 "${output_dir}/juicefs-secret.yaml"
  render_env_template "${env_file}" "${secrets_file}" "${manifest_dir}/storageclass-pvc.yaml" "${output_dir}/juicefs-storageclass-pvc.yaml"
}
