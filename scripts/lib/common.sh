#!/usr/bin/env bash

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

need_file() {
  local file="$1"
  test -f "${file}" || die "required file not found: ${file}"
}

need_dir() {
  local dir="$1"
  test -d "${dir}" || die "required directory not found: ${dir}"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

fingerprint_value() {
  local value="$1"
  local digest
  digest="$(sha256_text "${value}")"
  printf 'sha256:%s' "${digest:0:12}"
}

file_mode() {
  local file="$1"
  if stat -c '%a' "${file}" >/dev/null 2>&1; then
    stat -c '%a' "${file}"
  elif stat -f '%Lp' "${file}" >/dev/null 2>&1; then
    stat -f '%Lp' "${file}"
  else
    return 1
  fi
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 48
  fi
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

require_cli_value() {
  local flag="$1"
  local value="${2-}"
  if [[ $# -lt 2 || -z "${value}" || "${value}" == --* ]]; then
    die "${flag} requires a value"
  fi
}

require_public_base_url_port() {
  local port="$1"

  [[ "${port}" =~ ^[0-9]+$ ]] || die "public base URL port must be numeric"
  (( 10#${port} <= 65535 )) || die "public base URL port must be between 0 and 65535"
}

normalize_public_base_url() {
  local url="$1"
  local rest authority path port

  case "${url}" in
    http://*) rest="${url#http://}" ;;
    https://*) rest="${url#https://}" ;;
    *) die "public base URL must start with http:// or https://" ;;
  esac

  case "${rest}" in
    *\?*|*#*) die "public base URL must not include query or fragment" ;;
  esac

  authority="${rest%%/*}"
  path=""
  if [[ "${rest}" == */* ]]; then
    path="/${rest#*/}"
  fi

  [[ -n "${authority}" ]] || die "public base URL must include a host"
  [[ "${authority}" != *[[:space:]/\?#]* ]] || die "public base URL authority must be a host without whitespace, path, query, or fragment"
  [[ "${authority}" != *@* ]] || die "public base URL authority must not include userinfo"
  if [[ "${authority}" == \[* ]]; then
    [[ "${authority}" =~ ^\[[0-9A-Fa-f:.]+\](:[0-9]+)?$ ]] \
      || die "public base URL bracket IPv6 authority must be [IPv6] or [IPv6]:port"
    if [[ "${authority}" == *]:* ]]; then
      port="${authority##*:}"
      require_public_base_url_port "${port}"
    fi
  else
    [[ "${authority}" != *[\[\]]* ]] || die "public base URL authority has malformed IPv6 brackets"
    [[ "${authority}" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
      || die "public base URL authority must be host or host:port"
    if [[ "${authority}" == *:* ]]; then
      port="${authority##*:}"
      require_public_base_url_port "${port}"
    fi
  fi

  while [[ "${path}" == */ ]]; do
    path="${path%/}"
  done

  printf '%s%s' "${url%%://*}://${authority}" "${path}"
}

is_app_owned_image_ref() {
  local image_ref="$1"
  local repo_ref
  repo_ref="${image_ref%@sha256:*}"
  case "${repo_ref}" in
    *agentsmith-lite-api*|*agentsmith-lite-web*|*agentsmith-lite-app*|*botified-runner*)
      return 0
      ;;
    agentsmith-lite/app|agentsmith-lite/app:*|*/agentsmith-lite/app|*/agentsmith-lite/app:*)
      return 0
      ;;
  esac
  return 1
}

require_digest_pinned_image_ref() {
  local label="$1"
  local image_ref="$2"
  [[ "${image_ref}" =~ @sha256:[0-9a-f]{64}$ ]] \
    || die "${label} must be digest-pinned with @sha256:<64 lowercase hex>"
  if is_app_owned_image_ref "${image_ref}"; then
    die "${label} must not reference app-owned images"
  fi
}

require_helm_consumed_image_ref() {
  local label="$1"
  local image_ref="$2"
  local repo_tag last_segment
  require_digest_pinned_image_ref "${label}" "${image_ref}"
  repo_tag="${image_ref%@sha256:*}"
  last_segment="${repo_tag##*/}"
  [[ "${last_segment}" == *:* ]] \
    || die "${label} must include a tag before @sha256 for Helm values rendering"
}

helm_image_repository_tag() {
  local label="$1"
  local image_ref="$2"
  local digest_part repo_tag last_segment tag repository
  require_helm_consumed_image_ref "${label}" "${image_ref}"
  digest_part="${image_ref##*@}"
  repo_tag="${image_ref%@sha256:*}"
  last_segment="${repo_tag##*/}"
  tag="${last_segment##*:}"
  repository="${repo_tag%:${tag}}"
  [[ -n "${repository}" && -n "${tag}" ]] \
    || die "${label} must split into non-empty Helm repository and tag"
  printf '%s\t%s@%s\n' "${repository}" "${tag}" "${digest_part}"
}

safe_remove_dir() {
  local target="$1"
  [[ -n "${target}" ]] || die "refusing to remove an empty path"
  [[ "${target}" != "/" ]] || die "refusing to remove /"
  [[ -d "${target}" ]] || return 0

  local parent base abs_target
  parent="$(cd "$(dirname "${target}")" && pwd -P)"
  base="$(basename "${target}")"
  abs_target="${parent}/${base}"

  case "${abs_target}" in
    "/"|"${HOME}"|"${HOME}/"|"/tmp")
      die "refusing to remove dangerous path: ${abs_target}"
      ;;
  esac

  rm -rf -- "${abs_target}"
}
