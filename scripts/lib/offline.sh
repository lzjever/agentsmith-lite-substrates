#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

validate_offline_cache() {
  local cache_dir="$1"
  need_dir "${cache_dir}"
  need_file "${cache_dir}/manifest.yaml"
  need_file "${cache_dir}/checksums.txt"
  need_file "${cache_dir}/images/images.lock"

  grep -Fq 'schemaVersion: agentsmith-lite.substrate.offline-cache/v1' "${cache_dir}/manifest.yaml" \
    || die "offline cache manifest has unsupported schemaVersion"
  grep -Fq 'schemaVersion: agentsmith-lite.substrate.images/v1' "${cache_dir}/images/images.lock" \
    || die "images.lock has unsupported schemaVersion"

  if grep -Eiq '(^|[[:space:]])(publicDownloadUrl|downloadUrl|sourceUrl|url):[[:space:]]*https?://' "${cache_dir}/manifest.yaml"; then
    die "public download references are not allowed in offline cache manifest"
  fi

  local sum rel actual file
  while read -r sum rel; do
    [[ -n "${sum:-}" ]] || continue
    [[ "${sum}" =~ ^# ]] && continue
    file="${cache_dir}/${rel}"
    need_file "${file}"
    actual="$(sha256_file "${file}")"
    [[ "${actual}" == "${sum}" ]] || die "checksum mismatch for ${rel}"
  done <"${cache_dir}/checksums.txt"

  local image
  while IFS= read -r image; do
    [[ -n "${image}" ]] || continue
    if [[ ! "${image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
      die "images.lock image is not digest-pinned: ${image}"
    fi
    case "${image}" in
      *agentsmith-lite-api*|*agentsmith-lite-web*|*agentsmith-lite-app*|*botified-runner*)
        die "substrate offline cache must not include app-owned images: ${image}"
        ;;
    esac
  done < <(awk '/^[[:space:]]*image:/ { print $2 }' "${cache_dir}/images/images.lock")

  local archive
  while IFS= read -r archive; do
    [[ -n "${archive}" ]] || continue
    need_file "${cache_dir}/${archive}"
  done < <(awk '/^[[:space:]]*archive:/ { print $2 }' "${cache_dir}/images/images.lock")

  info "offline cache contract validated: ${cache_dir}"
}
