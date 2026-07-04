#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

artifact_lock_validate_syntax() {
  local file="$1"
  need_file "${file}"

  local bad duplicate
  bad="$(awk '
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      if (line !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        print NR
      }
    }
  ' "${file}")"
  [[ -z "${bad}" ]] || die "artifact lock contains invalid KEY=VALUE lines at: ${bad}"

  duplicate="$(awk '
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      idx=index(line, "=")
      if (idx == 0) { next }
      key=substr(line, 1, idx - 1)
      count[key] += 1
    }
    END {
      for (key in count) {
        if (count[key] > 1) {
          print key
          exit 0
        }
      }
      exit 1
    }
  ' "${file}" 2>/dev/null || true)"
  [[ -z "${duplicate}" ]] || die "artifact lock contains duplicate key ${duplicate}"
}

artifact_lock_value() {
  local file="$1"
  local key="$2"
  awk -v wanted="${key}" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      return v
    }
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      idx=index(line, "=")
      if (idx == 0) { next }
      key=trim(substr(line, 1, idx - 1))
      value=trim(substr(line, idx + 1))
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

artifact_lock_required_value() {
  local file="$1"
  local key="$2"
  local value
  if ! value="$(artifact_lock_value "${file}" "${key}")"; then
    die "artifact lock is missing required key ${key}"
  fi
  [[ -n "${value}" ]] || die "artifact lock key ${key} must not be empty"
  printf '%s' "${value}"
}

artifact_lock_required_sha256() {
  local file="$1"
  local key="$2"
  local value
  value="$(artifact_lock_required_value "${file}" "${key}")"
  [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || die "artifact lock key ${key} must be a lowercase sha256 hex digest"
  printf '%s' "${value}"
}

artifact_lock_required_url() {
  local file="$1"
  local key="$2"
  local value
  value="$(artifact_lock_required_value "${file}" "${key}")"
  case "${value}" in
    file://*|http://*|https://*)
      ;;
    *)
      die "artifact lock key ${key} must use file://, http://, or https://"
      ;;
  esac
  printf '%s' "${value}"
}

artifact_lock_required_digest_image() {
  local file="$1"
  local key="$2"
  local value
  value="$(artifact_lock_required_value "${file}" "${key}")"
  [[ "${value}" =~ @sha256:[0-9a-f]{64}$ ]] || die "${key} must be digest-pinned with @sha256:<64 lowercase hex>"
  case "${value}" in
    *agentsmith-lite-api*|*agentsmith-lite-web*|*agentsmith-lite-app*|*botified-runner*)
      die "${key} must not reference app-owned images"
      ;;
  esac
  printf '%s' "${value}"
}

download_verified_artifact() {
  local label="$1"
  local url="$2"
  local expected_sha="$3"
  local dest="$4"
  local actual

  mkdir -p "$(dirname "${dest}")"
  case "${url}" in
    file://*)
      local source_file="${url#file://}"
      [[ -f "${source_file}" ]] || die "source file for ${label} not found"
      cp -- "${source_file}" "${dest}" || die "failed to copy artifact ${label}"
      ;;
    http://*|https://*)
      command -v curl >/dev/null 2>&1 || die "curl is required to download ${label}"
      local curl_err="${dest}.curl.err"
      if ! curl -fsSL --retry 3 --connect-timeout 30 --output "${dest}" "${url}" 2>"${curl_err}"; then
        rm -f -- "${dest}" "${curl_err}"
        die "failed to download artifact ${label}"
      fi
      rm -f -- "${curl_err}"
      ;;
    *)
      die "unsupported URL scheme for ${label}"
      ;;
  esac

  actual="$(sha256_file "${dest}")"
  if [[ "${actual}" != "${expected_sha}" ]]; then
    rm -f -- "${dest}"
    die "downloaded artifact ${label} sha256 mismatch"
  fi
}
