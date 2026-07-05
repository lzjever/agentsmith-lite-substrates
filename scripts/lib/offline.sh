#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

offline_cache_mode() {
  local cache_dir="$1"
  local manifest_file
  manifest_file="$(cache_relative_path "${cache_dir}" "manifest.yaml" "manifest file")"
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
  ' "${manifest_file}" 2>/dev/null || true
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
      if (artifact_seen) {
        print path "\t" sha "\t" kind
      }
      artifact_seen=0
      path=""
      sha=""
      kind=""
    }
    /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
      flush()
      path=value_after_colon($0)
      artifact_seen=1
      sha=""
      kind=""
      next
    }
    /^[[:space:]]*path:[[:space:]]*/ {
      path=value_after_colon($0)
      artifact_seen=1
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
      if (archive_seen) {
        print archive "\t" sha
      }
      archive_seen=0
      archive=""
      sha=""
    }
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      flush()
      archive=""
      sha=""
      next
    }
    /^[[:space:]]*archive:[[:space:]]*/ {
      archive=value_after_colon($0)
      archive_seen=1
      next
    }
    /^[[:space:]]*sha256:[[:space:]]*/ {
      sha=value_after_colon($0)
      next
    }
    END { flush() }
  ' "${lock_file}"
}

images_lock_entries() {
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
      if (entry_seen) {
        print name "\t" image "\t" archive "\t" sha
      }
      entry_seen=0
      name=""
      image=""
      archive=""
      sha=""
    }
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      flush()
      name=value_after_colon($0)
      entry_seen=1
      next
    }
    entry_seen && /^[[:space:]]*image:[[:space:]]*/ {
      image=value_after_colon($0)
      next
    }
    entry_seen && /^[[:space:]]*archive:[[:space:]]*/ {
      archive=value_after_colon($0)
      next
    }
    entry_seen && /^[[:space:]]*sha256:[[:space:]]*/ {
      sha=value_after_colon($0)
      next
    }
    END { flush() }
  ' "${lock_file}"
}

substrate_allowed_image_archive() {
  local name="$1"
  case "${name}" in
    postgres) printf '%s\n' "images/oci/postgres.tar" ;;
    minio) printf '%s\n' "images/oci/minio.tar" ;;
    minio-client) printf '%s\n' "images/oci/minio-client.tar" ;;
    juicefs-csi) printf '%s\n' "images/oci/juicefs-csi.tar" ;;
    juicefs-csi-liveness-probe) printf '%s\n' "images/oci/juicefs-csi-liveness-probe.tar" ;;
    juicefs-csi-node-driver-registrar) printf '%s\n' "images/oci/juicefs-csi-node-driver-registrar.tar" ;;
    juicefs-csi-provisioner) printf '%s\n' "images/oci/juicefs-csi-provisioner.tar" ;;
    juicefs-csi-resizer) printf '%s\n' "images/oci/juicefs-csi-resizer.tar" ;;
    rwx-smoke) printf '%s\n' "images/oci/rwx-smoke.tar" ;;
    *) return 1 ;;
  esac
}

is_substrate_allowed_oci_archive() {
  local archive="$1"
  case "${archive}" in
    images/oci/postgres.tar|\
    images/oci/minio.tar|\
    images/oci/minio-client.tar|\
    images/oci/juicefs-csi.tar|\
    images/oci/juicefs-csi-liveness-probe.tar|\
    images/oci/juicefs-csi-node-driver-registrar.tar|\
    images/oci/juicefs-csi-provisioner.tar|\
    images/oci/juicefs-csi-resizer.tar|\
    images/oci/rwx-smoke.tar)
      return 0
      ;;
  esac
  return 1
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
  local file
  file="$(cache_relative_path "${cache_dir}" "${rel}" "p1-real executable artifact path")"
  [[ -x "${file}" ]] || die "p1-real artifact must be executable: ${rel}"
}

images_lock_entry_archive_sha() {
  local lock_file="$1"
  local name="$2"
  awk -v wanted="${name}" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    function value_after_colon(line) {
      return trim(substr(line, index(line, ":") + 1))
    }
    function emit() {
      print archive "\t" sha
      found=1
      done=1
    }
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      if (entry_seen && entry_name == wanted) {
        emit()
        exit 0
      }
      entry_name=value_after_colon($0)
      archive=""
      sha=""
      entry_seen=1
      next
    }
    entry_seen && /^[[:space:]]*archive:[[:space:]]*/ {
      archive=value_after_colon($0)
      next
    }
    entry_seen && /^[[:space:]]*sha256:[[:space:]]*/ {
      sha=value_after_colon($0)
      next
    }
    END {
      if (!done) {
        if (entry_seen && entry_name == wanted) {
          emit()
        } else {
          exit 1
        }
      }
    }
  ' "${lock_file}"
}

require_image_lock_archive() {
  local cache_dir="$1"
  local lock_file="$2"
  local name="$3"
  local expected_archive="$4"
  local record archive expected file actual

  record="$(images_lock_entry_archive_sha "${lock_file}" "${name}")" \
    || die "p1-real images.lock is missing dependency image entry: ${name}"
  IFS=$'\t' read -r archive expected <<<"${record}"
  [[ -n "${archive:-}" ]] || die "images.lock entry ${name} is missing archive"
  [[ "${archive}" == "${expected_archive}" ]] \
    || die "images.lock entry ${name} must declare archive: ${expected_archive}"
  [[ -n "${expected:-}" ]] || die "images.lock entry ${name} is missing sha256: ${expected_archive}"
  [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
    || die "images.lock entry ${name} has invalid sha256: ${expected_archive}"
  file="$(cache_relative_path "${cache_dir}" "${archive}" "images.lock archive path")"
  need_file "${file}"
  actual="$(sha256_file "${file}")"
  [[ "${actual}" == "${expected}" ]] \
    || die "images.lock entry ${name} sha256 mismatch for ${expected_archive}"
}

images_lock_image_ref() {
  local lock_file="$1"
  local name="$2"
  awk -v wanted="${name}" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", value)
      in_wanted=(trim(value) == wanted)
      next
    }
    in_wanted && /^[[:space:]]*image:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*image:[[:space:]]*/, "", value)
      print trim(value)
      found=1
      exit 0
    }
    END { if (!found) exit 1 }
  ' "${lock_file}"
}

validate_manifest_artifact_checksums() {
  local cache_dir="$1"
  local manifest_file path sha kind file actual
  manifest_file="$(cache_relative_path "${cache_dir}" "manifest.yaml" "manifest file")"
  while IFS=$'\t' read -r path sha kind; do
    file="$(cache_relative_path "${cache_dir}" "${path:-}" "manifest artifact path")"
    [[ -n "${sha:-}" ]] || die "offline cache manifest artifact ${path} is missing sha256"
    [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || die "offline cache manifest artifact ${path} has invalid sha256"
    need_file "${file}"
    actual="$(sha256_file "${file}")"
    [[ "${actual}" == "${sha}" ]] || die "offline cache manifest sha256 mismatch for ${path}"
    [[ -n "${kind:-}" ]] || die "offline cache manifest artifact ${path} is missing kind"
  done < <(manifest_artifacts "${manifest_file}")
}

validate_images_lock_archives() {
  local cache_dir="$1"
  local lock_file archive expected file actual
  lock_file="$(cache_relative_path "${cache_dir}" "images/images.lock" "images lock file")"
  while IFS=$'\t' read -r archive expected; do
    file="$(cache_relative_path "${cache_dir}" "${archive:-}" "images.lock archive path")"
    need_file "${file}"
    [[ -n "${expected:-}" ]] || die "images.lock archive entry is missing sha256: ${archive}"
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "images.lock archive entry has invalid sha256: ${archive}"
    actual="$(sha256_file "${file}")"
    [[ "${actual}" == "${expected}" ]] || die "images.lock archive sha256 mismatch for ${archive}"
  done < <(images_lock_archives "${lock_file}")
}

validate_images_lock_allowlist() {
  local lock_file="$1"
  local -A seen=()
  local name image archive expected_sha expected_archive

  while IFS=$'\t' read -r name image archive expected_sha; do
    [[ -n "${name:-}" ]] || die "images.lock contains an image entry without name"
    if ! expected_archive="$(substrate_allowed_image_archive "${name}")"; then
      die "substrate offline cache images.lock contains non-substrate image entry: ${name}"
    fi
    [[ -z "${seen[${name}]:-}" ]] || die "images.lock contains duplicate substrate image entry: ${name}"
    seen["${name}"]=1
    [[ -n "${archive:-}" ]] || die "images.lock entry ${name} is missing archive"
    [[ "${archive}" == "${expected_archive}" ]] \
      || die "images.lock entry ${name} must declare archive: ${expected_archive}"
  done < <(images_lock_entries "${lock_file}")
}

validate_manifest_oci_archive_allowlist() {
  local manifest_file="$1"
  local path sha kind
  while IFS=$'\t' read -r path sha kind; do
    [[ "${kind:-}" == "oci-archive" ]] || continue
    if ! is_substrate_allowed_oci_archive "${path:-}"; then
      die "offline cache manifest contains non-substrate OCI archive: ${path}"
    fi
  done < <(manifest_artifacts "${manifest_file}")
}

validate_oci_archive_files_allowlist() {
  local cache_dir="$1"
  local cache_root oci_dir file rel
  cache_root="$(cd "${cache_dir}" && pwd -P)" || die "required directory not found: ${cache_dir}"
  oci_dir="${cache_root}/images/oci"
  [[ -d "${oci_dir}" ]] || return 0

  while IFS= read -r file; do
    rel="${file#${cache_root}/}"
    if ! is_substrate_allowed_oci_archive "${rel}"; then
      die "offline cache images/oci contains non-substrate OCI archive: ${rel}"
    fi
  done < <(find "${oci_dir}" -type f -name '*.tar' -print)
}

cache_relative_path() {
  local cache_dir="$1"
  local rel="$2"
  local label="${3:-path}"
  local cache_root parent_rel base parent_abs full_path resolved

  [[ -n "${rel}" ]] || die "invalid cache-relative ${label}: empty paths are not allowed"
  [[ "${rel}" != /* ]] || die "invalid cache-relative ${label}: absolute paths are not allowed"
  [[ "${rel}" != *"://"* ]] || die "invalid cache-relative ${label}: URL-like paths are not allowed"
  case "${rel}" in
    ..|../*|*/..|*/../*)
      die "invalid cache-relative ${label}: parent traversal is not allowed"
      ;;
  esac

  cache_root="$(cd "${cache_dir}" && pwd -P)" || die "required directory not found: ${cache_dir}"
  parent_rel="$(dirname -- "${rel}")"
  base="$(basename -- "${rel}")"
  if [[ "${parent_rel}" == "." ]]; then
    parent_abs="${cache_root}"
  else
    parent_abs="$(cd "${cache_root}/${parent_rel}" && pwd -P)" \
      || die "required cache-relative directory not found for ${label}: ${rel}"
  fi

  case "${parent_abs}/" in
    "${cache_root}/"*) ;;
    *)
      die "cache-relative ${label} escapes cache root: ${rel}"
      ;;
  esac

  full_path="${parent_abs}/${base}"
  if [[ -e "${full_path}" ]]; then
    resolved="$(realpath "${full_path}" 2>/dev/null || readlink -f "${full_path}" 2>/dev/null || true)"
    if [[ -n "${resolved}" ]]; then
      case "${resolved}" in
        "${cache_root}"|"${cache_root}/"*) ;;
        *)
          die "cache-relative ${label} escapes cache root: ${rel}"
          ;;
      esac
      full_path="${resolved}"
    fi
  fi

  printf '%s\n' "${full_path}"
}

validate_no_public_download_references() {
  local cache_dir="$1"
  local rel="$2"
  local category="$3"
  local file
  file="$(cache_relative_path "${cache_dir}" "${rel}" "${category} path")"

  if grep -Eiq 'https?://' "${file}"; then
    die "public download references are not allowed in offline cache ${category}: ${rel}"
  fi
  if grep -Eiq '(^|[[:space:]-])([[:alnum:]_.-]*url):[[:space:]]*' "${file}"; then
    die "URL fields are not allowed in offline cache ${category}: ${rel}"
  fi
}

validate_checksums_txt_contract() {
  local cache_dir="$1"
  local checksums_file
  local -A checksums_seen=()
  local -A checksums_by_path=()
  local sum rel file actual
  checksums_file="$(cache_relative_path "${cache_dir}" "checksums.txt" "checksums file")"

  while read -r sum rel; do
    [[ -n "${sum:-}" ]] || continue
    [[ "${sum}" =~ ^# ]] && continue
    [[ -n "${rel:-}" ]] || die "checksums.txt has malformed entry"
    file="$(cache_relative_path "${cache_dir}" "${rel}" "checksums path")"
    [[ "${sum}" =~ ^[0-9a-f]{64}$ ]] || die "checksums.txt has invalid sha256 for ${rel}"
    need_file "${file}"
    actual="$(sha256_file "${file}")"
    [[ "${actual}" == "${sum}" ]] || die "checksum mismatch for ${rel}"
    if [[ -n "${checksums_seen[${rel}]:-}" && "${checksums_by_path[${rel}]}" != "${sum}" ]]; then
      die "checksums.txt has conflicting sha256 entries for ${rel}"
    fi
    checksums_seen["${rel}"]=1
    checksums_by_path["${rel}"]="${sum}"
  done <"${checksums_file}"

  [[ -n "${checksums_seen[manifest.yaml]:-}" ]] || die "checksums.txt is missing required entry: manifest.yaml"

  local manifest_file path sha kind
  manifest_file="$(cache_relative_path "${cache_dir}" "manifest.yaml" "manifest file")"
  while IFS=$'\t' read -r path sha kind; do
    cache_relative_path "${cache_dir}" "${path:-}" "manifest artifact path" >/dev/null
    [[ -n "${checksums_seen[${path}]:-}" ]] || die "checksums.txt is missing required entry: ${path}"
    if [[ -n "${sha:-}" && "${checksums_by_path[${path}]}" != "${sha}" ]]; then
      die "checksums.txt sha256 does not match manifest artifact for ${path}"
    fi
  done < <(manifest_artifacts "${manifest_file}")
}

validate_p1_real_cache() {
  local cache_dir="$1"
  local manifest_file lock_file
  manifest_file="$(cache_relative_path "${cache_dir}" "manifest.yaml" "manifest file")"
  lock_file="$(cache_relative_path "${cache_dir}" "images/images.lock" "images lock file")"

  require_manifest_artifact "${manifest_file}" "k3s-binary" "bin/k3s"
  require_manifest_artifact "${manifest_file}" "k3s-install-script" "scripts/install-k3s.sh"
  require_manifest_artifact "${manifest_file}" "k3s-airgap-images" "images/k3s/k3s-airgap-images-amd64.tar.zst"
  require_manifest_artifact "${manifest_file}" "kubectl-binary" "bin/kubectl"
  require_manifest_artifact "${manifest_file}" "helm-binary" "bin/helm"
  require_manifest_artifact "${manifest_file}" "script" "scripts/import-images.sh"
  require_manifest_artifact "${manifest_file}" "manifest" "manifests/namespace-bootstrap/namespace.yaml"
  require_manifest_artifact "${manifest_file}" "images-lock" "images/images.lock"
  require_manifest_artifact "${manifest_file}" "juicefs-csi-artifact" "charts/juicefs-csi.tgz"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/postgres.tar"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/minio.tar"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/minio-client.tar"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/juicefs-csi.tar"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/juicefs-csi-liveness-probe.tar"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/juicefs-csi-node-driver-registrar.tar"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/juicefs-csi-provisioner.tar"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/juicefs-csi-resizer.tar"
  require_manifest_artifact "${manifest_file}" "oci-archive" "images/oci/rwx-smoke.tar"

  require_executable_artifact "${cache_dir}" "bin/k3s"
  require_executable_artifact "${cache_dir}" "scripts/install-k3s.sh"
  require_executable_artifact "${cache_dir}" "bin/kubectl"
  require_executable_artifact "${cache_dir}" "bin/helm"
  require_executable_artifact "${cache_dir}" "scripts/import-images.sh"

  require_image_lock_archive "${cache_dir}" "${lock_file}" "postgres" "images/oci/postgres.tar"
  require_image_lock_archive "${cache_dir}" "${lock_file}" "minio" "images/oci/minio.tar"
  require_image_lock_archive "${cache_dir}" "${lock_file}" "minio-client" "images/oci/minio-client.tar"
  require_image_lock_archive "${cache_dir}" "${lock_file}" "juicefs-csi" "images/oci/juicefs-csi.tar"
  require_image_lock_archive "${cache_dir}" "${lock_file}" "juicefs-csi-liveness-probe" "images/oci/juicefs-csi-liveness-probe.tar"
  require_image_lock_archive "${cache_dir}" "${lock_file}" "juicefs-csi-node-driver-registrar" "images/oci/juicefs-csi-node-driver-registrar.tar"
  require_image_lock_archive "${cache_dir}" "${lock_file}" "juicefs-csi-provisioner" "images/oci/juicefs-csi-provisioner.tar"
  require_image_lock_archive "${cache_dir}" "${lock_file}" "juicefs-csi-resizer" "images/oci/juicefs-csi-resizer.tar"
  require_image_lock_archive "${cache_dir}" "${lock_file}" "rwx-smoke" "images/oci/rwx-smoke.tar"

  local helm_image_name helm_image
  for helm_image_name in \
    juicefs-csi \
    juicefs-csi-liveness-probe \
    juicefs-csi-node-driver-registrar \
    juicefs-csi-provisioner \
    juicefs-csi-resizer
  do
    helm_image="$(images_lock_image_ref "${lock_file}" "${helm_image_name}")" \
      || die "p1-real images.lock is missing dependency image entry: ${helm_image_name}"
    require_helm_consumed_image_ref "images.lock entry ${helm_image_name}" "${helm_image}"
  done
}

validate_offline_cache() {
  local cache_dir="$1"
  local manifest_file checksums_file lock_file
  need_dir "${cache_dir}"
  manifest_file="$(cache_relative_path "${cache_dir}" "manifest.yaml" "manifest file")"
  checksums_file="$(cache_relative_path "${cache_dir}" "checksums.txt" "checksums file")"
  lock_file="$(cache_relative_path "${cache_dir}" "images/images.lock" "images lock file")"
  need_file "${manifest_file}"
  need_file "${checksums_file}"
  need_file "${lock_file}"

  validate_no_public_download_references "${cache_dir}" "manifest.yaml" "manifest"
  validate_no_public_download_references "${cache_dir}" "checksums.txt" "checksums"
  validate_no_public_download_references "${cache_dir}" "images/images.lock" "images lock"

  grep -Fq 'schemaVersion: agentsmith-lite.substrate.offline-cache/v1' "${manifest_file}" \
    || die "offline cache manifest has unsupported schemaVersion"
  grep -Fq 'schemaVersion: agentsmith-lite.substrate.images/v1' "${lock_file}" \
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

  validate_checksums_txt_contract "${cache_dir}"

  validate_manifest_artifact_checksums "${cache_dir}"

  local image
  while IFS= read -r image; do
    [[ -n "${image}" ]] || continue
    if [[ ! "${image}" =~ @sha256:[0-9a-f]{64}$ ]]; then
      die "images.lock image is not digest-pinned: ${image}"
    fi
    if is_app_owned_image_ref "${image}"; then
      die "substrate offline cache must not include app-owned images"
    fi
  done < <(awk '/^[[:space:]]*image:/ { print $2 }' "${lock_file}")

  validate_images_lock_archives "${cache_dir}"
  validate_images_lock_allowlist "${lock_file}"
  validate_manifest_oci_archive_allowlist "${manifest_file}"
  validate_oci_archive_files_allowlist "${cache_dir}"

  if [[ "${cache_mode}" == "p1-real" ]]; then
    validate_p1_real_cache "${cache_dir}"
  fi

  info "offline cache contract validated (${cache_mode}): ${cache_dir}"
}
