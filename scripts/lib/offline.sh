#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

offline_cache_mode() {
  local cache_dir="$1"
  awk '
    /^[[:space:]]*cacheMode:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*cacheMode:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^\047|\047$/, "", value)
      print value
      found=1
    }
    END { if (!found) exit 1 }
  ' "${cache_dir}/manifest.yaml" 2>/dev/null || true
}

manifest_artifacts() {
  local manifest_file="$1"
  awk '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    function value_after_colon(line) {
      return trim(substr(line, index(line, ":") + 1))
    }
    function flush() {
      if (path != "") {
        print path "\t" sha "\t" kind
      }
    }
    /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
      flush()
      path=value_after_colon($0)
      sha=""
      kind=""
      next
    }
    /^[[:space:]]*path:[[:space:]]*/ {
      path=value_after_colon($0)
      next
    }
    /^[[:space:]]*sha256:[[:space:]]*/ {
      sha=value_after_colon($0)
      next
    }
    /^[[:space:]]*kind:[[:space:]]*/ {
      kind=value_after_colon($0)
      next
    }
    END { flush() }
  ' "${manifest_file}"
}

images_lock_archives() {
  local lock_file="$1"
  awk '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    function value_after_colon(line) {
      return trim(substr(line, index(line, ":") + 1))
    }
    function flush() {
      if (archive != "") {
        print archive "\t" sha
      }
    }
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      flush()
      archive=""
      sha=""
      next
    }
    /^[[:space:]]*archive:[[:space:]]*/ {
      archive=value_after_colon($0)
      next
    }
    /^[[:space:]]*sha256:[[:space:]]*/ {
      sha=value_after_colon($0)
      next
    }
    END { flush() }
  ' "${lock_file}"
}

require_manifest_artifact() {
  local manifest_file="$1"
  local kind="$2"
  local path="$3"
  if ! manifest_artifacts "${manifest_file}" | awk -F '\t' -v want_path="${path}" -v want_kind="${kind}" '
    $1 == want_path && $3 == want_kind { found=1 }
    END { exit found ? 0 : 1 }
  '; then
    die "missing required p1-real artifact ${path} with kind ${kind}"
  fi
}

require_executable_artifact() {
  local cache_dir="$1"
  local rel="$2"
  [[ -x "${cache_dir}/${rel}" ]] || die "p1-real artifact must be executable: ${rel}"
}

require_image_lock_name() {
  local lock_file="$1"
  local name="$2"
  if ! awk -v wanted="${name}" '
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^\047|\047$/, "", value)
      if (value == wanted) {
        found=1
      }
    }
    END { exit found ? 0 : 1 }
  ' "${lock_file}"; then
    die "p1-real images.lock is missing dependency image entry: ${name}"
  fi
}

validate_manifest_artifact_checksums() {
  local cache_dir="$1"
  local path sha kind actual
  while IFS=$'\t' read -r path sha kind; do
    [[ -n "${path:-}" ]] || continue
    [[ -n "${sha:-}" ]] || die "offline cache manifest artifact ${path} is missing sha256"
    [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || die "offline cache manifest artifact ${path} has invalid sha256"
    need_file "${cache_dir}/${path}"
    actual="$(sha256_file "${cache_dir}/${path}")"
    [[ "${actual}" == "${sha}" ]] || die "offline cache manifest sha256 mismatch for ${path}"
    [[ -n "${kind:-}" ]] || die "offline cache manifest artifact ${path} is missing kind"
  done < <(manifest_artifacts "${cache_dir}/manifest.yaml")
}

validate_images_lock_archives() {
  local cache_dir="$1"
  local archive expected actual
  while IFS=$'\t' read -r archive expected; do
    [[ -n "${archive:-}" ]] || continue
    need_file "${cache_dir}/${archive}"
    [[ -n "${expected:-}" ]] || die "images.lock archive entry is missing sha256: ${archive}"
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "images.lock archive entry has invalid sha256: ${archive}"
    actual="$(sha256_file "${cache_dir}/${archive}")"
    [[ "${actual}" == "${expected}" ]] || die "images.lock archive sha256 mismatch for ${archive}"
  done < <(images_lock_archives "${cache_dir}/images/images.lock")
}

validate_p1_real_cache() {
  local cache_dir="$1"
  local manifest_file="${cache_dir}/manifest.yaml"
  local lock_file="${cache_dir}/images/images.lock"

  require_manifest_artifact "${manifest_file}" "k3s-binary" "bin/k3s"
  require_manifest_artifact "${manifest_file}" "k3s-install-script" "scripts/install-k3s.sh"
  require_manifest_artifact "${manifest_file}" "k3s-airgap-images" "images/k3s/k3s-airgap-images-amd64.tar.zst"
  require_manifest_artifact "${manifest_file}" "kubectl-binary" "bin/kubectl"
  require_manifest_artifact "${manifest_file}" "images-lock" "images/images.lock"
  require_manifest_artifact "${manifest_file}" "juicefs-csi-artifact" "charts/juicefs-csi.tgz"

  require_executable_artifact "${cache_dir}" "bin/k3s"
  require_executable_artifact "${cache_dir}" "scripts/install-k3s.sh"
  require_executable_artifact "${cache_dir}" "bin/kubectl"

  require_image_lock_name "${lock_file}" "postgres"
  require_image_lock_name "${lock_file}" "minio"
  require_image_lock_name "${lock_file}" "juicefs-csi"
}

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

  local cache_mode
  cache_mode="$(offline_cache_mode "${cache_dir}")"
  case "${cache_mode}" in
    p0-contract|p1-real)
      ;;
    "")
      die "offline cache manifest is missing cacheMode"
      ;;
    *)
      die "offline cache manifest has unsupported cacheMode: ${cache_mode}"
      ;;
  esac

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

  validate_manifest_artifact_checksums "${cache_dir}"

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

  validate_images_lock_archives "${cache_dir}"

  if [[ "${cache_mode}" == "p1-real" ]]; then
    validate_p1_real_cache "${cache_dir}"
  fi

  info "offline cache contract validated (${cache_mode}): ${cache_dir}"
}
