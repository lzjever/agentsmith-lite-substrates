#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

usage() {
  cat <<'EOF_USAGE'
Usage:
  scripts/prepare-offline-cache.sh [--artifacts-dir out/artifacts] [--output dist/offline-cache] [--force]

Downloads fixed-version substrate artifacts, resolves and exports required
substrate images with skopeo, writes out/artifacts/offline-artifacts.env, then
calls scripts/download-online.sh to produce a cacheMode: p1-real cache.

Common overrides:
  OFFLINE_ARTIFACTS_DIR=out/artifacts
  OFFLINE_CACHE_OUTPUT=dist/offline-cache
  PREPARE_OFFLINE_CACHE_FORCE=true
  K3S_VERSION=v1.36.2+k3s1
  KUBECTL_VERSION=v1.36.2
  HELM_VERSION=v3.21.2
  JUICEFS_CSI_CHART_VERSION=0.31.10
  POSTGRES_SOURCE=docker.io/library/postgres:16
  MINIO_SOURCE=docker.io/minio/minio:RELEASE.2025-09-07T16-13-09Z
  MINIO_CLIENT_SOURCE=docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z
  KEYCLOAK_SOURCE=quay.io/keycloak/keycloak:26.0.7
  JUICEFS_CSI_SOURCE=docker.io/juicedata/juicefs-csi-driver:v0.31.10
  RWX_CHECK_SOURCE=docker.io/library/busybox:1.36.1
  LOCAL_OPENAI_PROVIDER_SOURCE=docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0
EOF_USAGE
}

require_command() {
  local tool="$1"
  command -v "${tool}" >/dev/null 2>&1 || die "${tool} is required"
}

absolute_dir_path() {
  local dir="$1"
  local parent base
  [[ -n "${dir}" ]] || die "directory path must not be empty"
  [[ "${dir}" != "/" ]] || die "directory path must not be /"
  parent="$(dirname -- "${dir}")"
  base="$(basename -- "${dir}")"
  mkdir -p "${parent}"
  parent="$(cd "${parent}" && pwd -P)"
  printf '%s/%s\n' "${parent}" "${base}"
}

prepare_artifacts_dir() {
  local dir="$1"
  if [[ -d "${dir}" && "${force}" != "true" ]]; then
    if [[ -n "$(find "${dir}" -mindepth 1 -print -quit)" ]]; then
      die "${dir} already exists and is not empty; rerun with --force to overwrite"
    fi
  fi
  if [[ -e "${dir}" && ! -d "${dir}" ]]; then
    die "${dir} exists and is not a directory"
  fi
  safe_remove_dir "${dir}"
  mkdir -p "${dir}/bin" "${dir}/charts" "${dir}/images/oci" "${dir}/images/k3s"
}

download_file() {
  local label="$1"
  local url="$2"
  local dest="$3"
  local tmp
  [[ -n "${url}" ]] || die "${label} source URL must not be empty"
  mkdir -p "$(dirname "${dest}")"
  tmp="${dest}.tmp"
  rm -f -- "${tmp}"
  if ! curl -fsSL --retry 3 --connect-timeout 30 --output "${tmp}" "${url}"; then
    rm -f -- "${tmp}"
    die "failed to download ${label}"
  fi
  mv "${tmp}" "${dest}"
}

require_tagged_image_source() {
  local label="$1"
  local source="$2"
  local repo_tag last_segment
  repo_tag="${source%@sha256:*}"
  last_segment="${repo_tag##*/}"
  [[ "${last_segment}" == *:* ]] \
    || die "${label} must include a tag so the lock can be written as repo:tag@sha256:<digest>"
}

resolve_image_digest() {
  local label="$1"
  local source="$2"
  local digest inspect_source repo_tag
  require_tagged_image_source "${label}" "${source}"
  inspect_source="${source}"
  if [[ "${source}" == *@sha256:* ]]; then
    repo_tag="${source%@sha256:*}"
    inspect_source="${repo_tag%:*}@${source##*@}"
  fi
  if ! digest="$(skopeo inspect --override-os linux --override-arch amd64 --format '{{.Digest}}' "docker://${inspect_source}")"; then
    die "failed to resolve digest for ${label}"
  fi
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "skopeo returned an invalid digest for ${label}"
  printf '%s\n' "${digest#sha256:}"
}

export_image_archive() {
  local label="$1"
  local digest_source="$2"
  local archive="$3"
  local archive_tag="$4"
  mkdir -p "$(dirname "${archive}")"
  if ! skopeo copy --override-os linux --override-arch amd64 "docker://${digest_source}" "docker-archive:${archive}:${archive_tag}" >/dev/null; then
    rm -f -- "${archive}"
    die "failed to export ${label} image archive"
  fi
}

prepare_image_artifact() {
  local label="$1"
  local source="$2"
  local archive="$3"
  local digest repo_tag digest_source pinned_source archive_sha
  digest="$(resolve_image_digest "${label}" "${source}")"
  repo_tag="${source%@sha256:*}"
  pinned_source="${repo_tag}@sha256:${digest}"
  digest_source="${repo_tag%:*}@sha256:${digest}"
  export_image_archive "${label}" "${digest_source}" "${archive}" "${repo_tag}"
  archive_sha="$(sha256_file "${archive}")"
  printf '%s\t%s\t%s\n' "${archive}" "${pinned_source}" "${archive_sha}"
}

write_artifact_lock() {
  local lock_file="$1"
  local postgres_record="$2"
  local minio_record="$3"
  local minio_client_record="$4"
  local keycloak_record="$5"
  local juicefs_record="$6"
  local liveness_record="$7"
  local registrar_record="$8"
  local provisioner_record="$9"
  local resizer_record="${10}"
  local rwx_check_record="${11}"
  local local_openai_record="${12}"

  local postgres_archive postgres_image postgres_sha
  local minio_archive minio_image minio_sha
  local minio_client_archive minio_client_image minio_client_sha
  local keycloak_archive keycloak_image keycloak_sha
  local juicefs_archive juicefs_image juicefs_sha
  local liveness_archive liveness_image liveness_sha
  local registrar_archive registrar_image registrar_sha
  local provisioner_archive provisioner_image provisioner_sha
  local resizer_archive resizer_image resizer_sha
  local rwx_check_archive rwx_check_image rwx_check_sha
  local local_openai_archive local_openai_image local_openai_sha

  IFS=$'\t' read -r postgres_archive postgres_image postgres_sha <<<"${postgres_record}"
  IFS=$'\t' read -r minio_archive minio_image minio_sha <<<"${minio_record}"
  IFS=$'\t' read -r minio_client_archive minio_client_image minio_client_sha <<<"${minio_client_record}"
  IFS=$'\t' read -r keycloak_archive keycloak_image keycloak_sha <<<"${keycloak_record}"
  IFS=$'\t' read -r juicefs_archive juicefs_image juicefs_sha <<<"${juicefs_record}"
  IFS=$'\t' read -r liveness_archive liveness_image liveness_sha <<<"${liveness_record}"
  IFS=$'\t' read -r registrar_archive registrar_image registrar_sha <<<"${registrar_record}"
  IFS=$'\t' read -r provisioner_archive provisioner_image provisioner_sha <<<"${provisioner_record}"
  IFS=$'\t' read -r resizer_archive resizer_image resizer_sha <<<"${resizer_record}"
  IFS=$'\t' read -r rwx_check_archive rwx_check_image rwx_check_sha <<<"${rwx_check_record}"
  IFS=$'\t' read -r local_openai_archive local_openai_image local_openai_sha <<<"${local_openai_record}"

  cat >"${lock_file}" <<EOF_LOCK
# Generated by scripts/prepare-offline-cache.sh. Non-secret artifact lock.
K3S_BINARY_URL=file://${ARTIFACTS_DIR_ABS}/bin/k3s
K3S_BINARY_SHA256=$(sha256_file "${ARTIFACTS_DIR_ABS}/bin/k3s")
K3S_INSTALL_SCRIPT_URL=file://${ARTIFACTS_DIR_ABS}/scripts/install-k3s.sh
K3S_INSTALL_SCRIPT_SHA256=$(sha256_file "${ARTIFACTS_DIR_ABS}/scripts/install-k3s.sh")
K3S_AIRGAP_IMAGES_URL=file://${ARTIFACTS_DIR_ABS}/images/k3s/k3s-airgap-images-amd64.tar.zst
K3S_AIRGAP_IMAGES_SHA256=$(sha256_file "${ARTIFACTS_DIR_ABS}/images/k3s/k3s-airgap-images-amd64.tar.zst")

KUBECTL_BINARY_URL=file://${ARTIFACTS_DIR_ABS}/bin/kubectl
KUBECTL_BINARY_SHA256=$(sha256_file "${ARTIFACTS_DIR_ABS}/bin/kubectl")

HELM_BINARY_URL=file://${ARTIFACTS_DIR_ABS}/bin/helm
HELM_BINARY_SHA256=$(sha256_file "${ARTIFACTS_DIR_ABS}/bin/helm")

JUICEFS_CSI_ARTIFACT_URL=file://${ARTIFACTS_DIR_ABS}/charts/juicefs-csi.tgz
JUICEFS_CSI_ARTIFACT_SHA256=$(sha256_file "${ARTIFACTS_DIR_ABS}/charts/juicefs-csi.tgz")

POSTGRES_IMAGE=${postgres_image}
POSTGRES_ARCHIVE_URL=file://${postgres_archive}
POSTGRES_ARCHIVE_SHA256=${postgres_sha}

MINIO_IMAGE=${minio_image}
MINIO_ARCHIVE_URL=file://${minio_archive}
MINIO_ARCHIVE_SHA256=${minio_sha}

MINIO_CLIENT_IMAGE=${minio_client_image}
MINIO_CLIENT_ARCHIVE_URL=file://${minio_client_archive}
MINIO_CLIENT_ARCHIVE_SHA256=${minio_client_sha}

KEYCLOAK_IMAGE=${keycloak_image}
KEYCLOAK_ARCHIVE_URL=file://${keycloak_archive}
KEYCLOAK_ARCHIVE_SHA256=${keycloak_sha}

JUICEFS_CSI_IMAGE=${juicefs_image}
JUICEFS_CSI_ARCHIVE_URL=file://${juicefs_archive}
JUICEFS_CSI_ARCHIVE_SHA256=${juicefs_sha}

JUICEFS_CSI_LIVENESS_PROBE_IMAGE=${liveness_image}
JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_URL=file://${liveness_archive}
JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_SHA256=${liveness_sha}

JUICEFS_CSI_NODE_DRIVER_REGISTRAR_IMAGE=${registrar_image}
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_URL=file://${registrar_archive}
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_SHA256=${registrar_sha}

JUICEFS_CSI_PROVISIONER_IMAGE=${provisioner_image}
JUICEFS_CSI_PROVISIONER_ARCHIVE_URL=file://${provisioner_archive}
JUICEFS_CSI_PROVISIONER_ARCHIVE_SHA256=${provisioner_sha}

JUICEFS_CSI_RESIZER_IMAGE=${resizer_image}
JUICEFS_CSI_RESIZER_ARCHIVE_URL=file://${resizer_archive}
JUICEFS_CSI_RESIZER_ARCHIVE_SHA256=${resizer_sha}

RWX_CHECK_IMAGE=${rwx_check_image}
RWX_CHECK_ARCHIVE_URL=file://${rwx_check_archive}
RWX_CHECK_ARCHIVE_SHA256=${rwx_check_sha}

LOCAL_OPENAI_PROVIDER_IMAGE=${local_openai_image}
LOCAL_OPENAI_PROVIDER_ARCHIVE_URL=file://${local_openai_archive}
LOCAL_OPENAI_PROVIDER_ARCHIVE_SHA256=${local_openai_sha}
EOF_LOCK
}

main() {
artifacts_dir="${OFFLINE_ARTIFACTS_DIR:-${ARTIFACTS_DIR:-out/artifacts}}"
output_dir="${OFFLINE_CACHE_OUTPUT:-${OUTPUT_DIR:-dist/offline-cache}}"
force_value="${PREPARE_OFFLINE_CACHE_FORCE:-${FORCE:-false}}"
if truthy "${force_value}"; then
  force=true
else
  force=false
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-dir)
      require_cli_value "$1" "${2-}"
      artifacts_dir="${2:-}"
      shift 2
      ;;
    --output)
      require_cli_value "$1" "${2-}"
      output_dir="${2:-}"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    --no-force)
      force=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.2}"
HELM_VERSION="${HELM_VERSION:-v3.21.2}"
JUICEFS_CSI_CHART_VERSION="${JUICEFS_CSI_CHART_VERSION:-0.31.10}"

K3S_BINARY_SOURCE_URL="${K3S_BINARY_SOURCE_URL:-https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s}"
K3S_INSTALL_SCRIPT_SOURCE_URL="${K3S_INSTALL_SCRIPT_SOURCE_URL:-https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh}"
K3S_AIRGAP_IMAGES_SOURCE_URL="${K3S_AIRGAP_IMAGES_SOURCE_URL:-https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-airgap-images-amd64.tar.zst}"
KUBECTL_BINARY_SOURCE_URL="${KUBECTL_BINARY_SOURCE_URL:-https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl}"
HELM_TARBALL_SOURCE_URL="${HELM_TARBALL_SOURCE_URL:-https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz}"
JUICEFS_CSI_CHART_SOURCE_URL="${JUICEFS_CSI_CHART_SOURCE_URL:-https://github.com/juicedata/charts/releases/download/helm-chart-juicefs-csi-driver-${JUICEFS_CSI_CHART_VERSION}/juicefs-csi-driver-${JUICEFS_CSI_CHART_VERSION}.tgz}"

POSTGRES_SOURCE="${POSTGRES_SOURCE:-docker.io/library/postgres:16}"
MINIO_SOURCE="${MINIO_SOURCE:-docker.io/minio/minio:RELEASE.2025-09-07T16-13-09Z}"
MINIO_CLIENT_SOURCE="${MINIO_CLIENT_SOURCE:-docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z}"
KEYCLOAK_SOURCE="${KEYCLOAK_SOURCE:-quay.io/keycloak/keycloak:26.0.7}"
JUICEFS_CSI_SOURCE="${JUICEFS_CSI_SOURCE:-docker.io/juicedata/juicefs-csi-driver:v0.31.10}"
JUICEFS_CSI_LIVENESS_PROBE_SOURCE="${JUICEFS_CSI_LIVENESS_PROBE_SOURCE:-registry.k8s.io/sig-storage/livenessprobe:v2.12.0}"
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_SOURCE="${JUICEFS_CSI_NODE_DRIVER_REGISTRAR_SOURCE:-registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.9.0}"
JUICEFS_CSI_PROVISIONER_SOURCE="${JUICEFS_CSI_PROVISIONER_SOURCE:-registry.k8s.io/sig-storage/csi-provisioner:v2.2.2}"
JUICEFS_CSI_RESIZER_SOURCE="${JUICEFS_CSI_RESIZER_SOURCE:-registry.k8s.io/sig-storage/csi-resizer:v1.9.0}"
RWX_CHECK_SOURCE="${RWX_CHECK_SOURCE:-docker.io/library/busybox:1.36.1}"
LOCAL_OPENAI_PROVIDER_SOURCE="${LOCAL_OPENAI_PROVIDER_SOURCE:-docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0}"

require_command curl
require_command tar
require_command skopeo
require_command sha256sum

ARTIFACTS_DIR_ABS="$(absolute_dir_path "${artifacts_dir}")"
OUTPUT_DIR_ABS="$(absolute_dir_path "${output_dir}")"
lock_file="${ARTIFACTS_DIR_ABS}/offline-artifacts.env"

prepare_artifacts_dir "${ARTIFACTS_DIR_ABS}"
mkdir -p "${ARTIFACTS_DIR_ABS}/scripts"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

download_file "k3s binary" "${K3S_BINARY_SOURCE_URL}" "${ARTIFACTS_DIR_ABS}/bin/k3s"
download_file "k3s install script" "${K3S_INSTALL_SCRIPT_SOURCE_URL}" "${ARTIFACTS_DIR_ABS}/scripts/install-k3s.sh"
download_file "k3s airgap images" "${K3S_AIRGAP_IMAGES_SOURCE_URL}" "${ARTIFACTS_DIR_ABS}/images/k3s/k3s-airgap-images-amd64.tar.zst"
download_file "kubectl binary" "${KUBECTL_BINARY_SOURCE_URL}" "${ARTIFACTS_DIR_ABS}/bin/kubectl"
download_file "Helm tarball" "${HELM_TARBALL_SOURCE_URL}" "${tmp_dir}/helm.tar.gz"
tar -xzf "${tmp_dir}/helm.tar.gz" -C "${tmp_dir}" linux-amd64/helm
need_file "${tmp_dir}/linux-amd64/helm"
cp -- "${tmp_dir}/linux-amd64/helm" "${ARTIFACTS_DIR_ABS}/bin/helm"
download_file "JuiceFS CSI chart" "${JUICEFS_CSI_CHART_SOURCE_URL}" "${ARTIFACTS_DIR_ABS}/charts/juicefs-csi.tgz"
chmod +x "${ARTIFACTS_DIR_ABS}/bin/k3s" \
  "${ARTIFACTS_DIR_ABS}/scripts/install-k3s.sh" \
  "${ARTIFACTS_DIR_ABS}/bin/kubectl" \
  "${ARTIFACTS_DIR_ABS}/bin/helm"

postgres_record="$(prepare_image_artifact "POSTGRES_SOURCE" "${POSTGRES_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/postgres.tar")"
minio_record="$(prepare_image_artifact "MINIO_SOURCE" "${MINIO_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/minio.tar")"
minio_client_record="$(prepare_image_artifact "MINIO_CLIENT_SOURCE" "${MINIO_CLIENT_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/minio-client.tar")"
keycloak_record="$(prepare_image_artifact "KEYCLOAK_SOURCE" "${KEYCLOAK_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/keycloak.tar")"
juicefs_record="$(prepare_image_artifact "JUICEFS_CSI_SOURCE" "${JUICEFS_CSI_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/juicefs-csi.tar")"
liveness_record="$(prepare_image_artifact "JUICEFS_CSI_LIVENESS_PROBE_SOURCE" "${JUICEFS_CSI_LIVENESS_PROBE_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/juicefs-csi-liveness-probe.tar")"
registrar_record="$(prepare_image_artifact "JUICEFS_CSI_NODE_DRIVER_REGISTRAR_SOURCE" "${JUICEFS_CSI_NODE_DRIVER_REGISTRAR_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/juicefs-csi-node-driver-registrar.tar")"
provisioner_record="$(prepare_image_artifact "JUICEFS_CSI_PROVISIONER_SOURCE" "${JUICEFS_CSI_PROVISIONER_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/juicefs-csi-provisioner.tar")"
resizer_record="$(prepare_image_artifact "JUICEFS_CSI_RESIZER_SOURCE" "${JUICEFS_CSI_RESIZER_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/juicefs-csi-resizer.tar")"
rwx_check_record="$(prepare_image_artifact "RWX_CHECK_SOURCE" "${RWX_CHECK_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/rwx-check.tar")"
local_openai_record="$(prepare_image_artifact "LOCAL_OPENAI_PROVIDER_SOURCE" "${LOCAL_OPENAI_PROVIDER_SOURCE}" "${ARTIFACTS_DIR_ABS}/images/oci/local-openai-provider.tar")"

write_artifact_lock "${lock_file}" \
  "${postgres_record}" \
  "${minio_record}" \
  "${minio_client_record}" \
  "${keycloak_record}" \
  "${juicefs_record}" \
  "${liveness_record}" \
  "${registrar_record}" \
  "${provisioner_record}" \
  "${resizer_record}" \
  "${rwx_check_record}" \
  "${local_openai_record}"
info "wrote artifact lock: ${lock_file}"

download_args=(--artifacts "${lock_file}" --output "${OUTPUT_DIR_ABS}")
if [[ "${force}" == "true" ]]; then
  download_args+=(--force)
fi
"${ROOT_DIR}/scripts/download-online.sh" "${download_args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
