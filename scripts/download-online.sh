#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
# shellcheck source=lib/download.sh
source "${ROOT_DIR}/scripts/lib/download.sh"
# shellcheck source=lib/offline.sh
source "${ROOT_DIR}/scripts/lib/offline.sh"

usage() {
  cat <<'EOF_USAGE'
Usage:
  scripts/download-online.sh --output dist/offline-cache [--force] [--contract-only]
  scripts/download-online.sh --artifacts config/offline-artifacts.env --output dist/offline-cache --force

Without --artifacts this writes the P0 offline cache contract skeleton.

With --artifacts this reads a non-secret KEY=VALUE artifact lock, downloads and
sha256-verifies the referenced files, and writes a cacheMode: p1-real offline
cache. This producer does not include app images, Botified runner images, or app
secrets, and it does not perform a live cluster install.
EOF_USAGE
}

output_dir="dist/offline-cache"
force=false
artifact_lock=""
contract_only=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      require_cli_value "$1" "${2-}"
      output_dir="${2:-}"
      shift 2
      ;;
    --artifacts)
      require_cli_value "$1" "${2-}"
      artifact_lock="${2:-}"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    --contract-only)
      contract_only=true
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

[[ -n "${output_dir}" ]] || die "--output must not be empty"
if [[ -n "${artifact_lock}" && "${contract_only}" == "true" ]]; then
  die "--artifacts and --contract-only are mutually exclusive"
fi

prepare_output_dir() {
  local dir="$1"
  if [[ -e "${dir}/manifest.yaml" && "${force}" != "true" ]]; then
    die "${dir}/manifest.yaml already exists; rerun with --force to overwrite"
  fi
  safe_remove_dir "${dir}"
  mkdir -p "${dir}/images/oci" "${dir}/manifests/namespace-bootstrap" "${dir}/scripts" "${dir}/bin" "${dir}/charts"
}

write_p0_contract_cache() {
  local dir="$1"
  prepare_output_dir "${dir}"
  printf 'P0 Keycloak placeholder archive; not a runnable OCI archive.\n' >"${dir}/images/oci/keycloak.tar"

  cat >"${dir}/scripts/import-images.sh" <<'EOF_IMPORT'
#!/usr/bin/env bash
set -euo pipefail
printf 'P0 contract skeleton has no runnable OCI archives to import and is not a real offline install cache.\n'
EOF_IMPORT
  chmod +x "${dir}/scripts/import-images.sh"

  cp "${ROOT_DIR}/manifests/namespace/namespace.yaml" "${dir}/manifests/namespace-bootstrap/namespace.yaml"

  local keycloak_sum import_sum namespace_sum lock_sum manifest_sum
  keycloak_sum="$(sha256_file "${dir}/images/oci/keycloak.tar")"

  cat >"${dir}/images/images.lock" <<EOF_LOCK
schemaVersion: agentsmith-lite.substrate.images/v1
images:
  - name: keycloak
    image: quay.io/keycloak/keycloak:26.0.7@sha256:1111111111111111111111111111111111111111111111111111111111111111
    archive: images/oci/keycloak.tar
    sha256: ${keycloak_sum}
EOF_LOCK

  import_sum="$(sha256_file "${dir}/scripts/import-images.sh")"
  namespace_sum="$(sha256_file "${dir}/manifests/namespace-bootstrap/namespace.yaml")"
  lock_sum="$(sha256_file "${dir}/images/images.lock")"

  cat >"${dir}/manifest.yaml" <<EOF_MANIFEST
schemaVersion: agentsmith-lite.substrate.offline-cache/v1
cacheMode: p0-contract
note: "P0 static contract skeleton only; not a real offline install cache"
artifacts:
  - path: scripts/import-images.sh
    sha256: ${import_sum}
    kind: script
  - path: manifests/namespace-bootstrap/namespace.yaml
    sha256: ${namespace_sum}
    kind: manifest
  - path: images/images.lock
    sha256: ${lock_sum}
    kind: images-lock
  - path: images/oci/keycloak.tar
    sha256: ${keycloak_sum}
    kind: oci-archive
EOF_MANIFEST

  manifest_sum="$(sha256_file "${dir}/manifest.yaml")"
  cat >"${dir}/checksums.txt" <<EOF_SUMS
${manifest_sum}  manifest.yaml
${import_sum}  scripts/import-images.sh
${namespace_sum}  manifests/namespace-bootstrap/namespace.yaml
${lock_sum}  images/images.lock
${keycloak_sum}  images/oci/keycloak.tar
EOF_SUMS

  validate_offline_cache "${dir}"
  info "wrote P0 offline cache contract skeleton: ${dir}"
  info "note: this cache is not a real offline install cache; p1-real requires k3s, kubectl, k3s airgap images, dependency OCI archives, and a JuiceFS CSI artifact"
}

write_p1_real_cache() {
  local lock_file="$1"
  local dir="$2"

  artifact_lock_validate_syntax "${lock_file}"

  local k3s_url k3s_sha install_url install_sha airgap_url airgap_sha kubectl_url kubectl_sha helm_url helm_sha
  local csi_chart_url csi_chart_sha postgres_image postgres_url postgres_sha minio_image minio_url minio_sha
  local minio_client_image minio_client_url minio_client_sha keycloak_image keycloak_url keycloak_sha
  local juicefs_image juicefs_url juicefs_sha
  local liveness_image liveness_url liveness_sha registrar_image registrar_url registrar_sha
  local provisioner_image provisioner_url provisioner_sha resizer_image resizer_url resizer_sha
  local rwx_check_image rwx_check_url rwx_check_sha local_openai_image local_openai_url local_openai_sha
  k3s_url="$(artifact_lock_required_url "${lock_file}" "K3S_BINARY_URL")"
  k3s_sha="$(artifact_lock_required_sha256 "${lock_file}" "K3S_BINARY_SHA256")"
  install_url="$(artifact_lock_required_url "${lock_file}" "K3S_INSTALL_SCRIPT_URL")"
  install_sha="$(artifact_lock_required_sha256 "${lock_file}" "K3S_INSTALL_SCRIPT_SHA256")"
  airgap_url="$(artifact_lock_required_url "${lock_file}" "K3S_AIRGAP_IMAGES_URL")"
  airgap_sha="$(artifact_lock_required_sha256 "${lock_file}" "K3S_AIRGAP_IMAGES_SHA256")"
  kubectl_url="$(artifact_lock_required_url "${lock_file}" "KUBECTL_BINARY_URL")"
  kubectl_sha="$(artifact_lock_required_sha256 "${lock_file}" "KUBECTL_BINARY_SHA256")"
  helm_url="$(artifact_lock_required_url "${lock_file}" "HELM_BINARY_URL")"
  helm_sha="$(artifact_lock_required_sha256 "${lock_file}" "HELM_BINARY_SHA256")"
  csi_chart_url="$(artifact_lock_required_url "${lock_file}" "JUICEFS_CSI_ARTIFACT_URL")"
  csi_chart_sha="$(artifact_lock_required_sha256 "${lock_file}" "JUICEFS_CSI_ARTIFACT_SHA256")"
  postgres_image="$(artifact_lock_required_digest_image "${lock_file}" "POSTGRES_IMAGE")"
  postgres_url="$(artifact_lock_required_url "${lock_file}" "POSTGRES_ARCHIVE_URL")"
  postgres_sha="$(artifact_lock_required_sha256 "${lock_file}" "POSTGRES_ARCHIVE_SHA256")"
  minio_image="$(artifact_lock_required_digest_image "${lock_file}" "MINIO_IMAGE")"
  minio_url="$(artifact_lock_required_url "${lock_file}" "MINIO_ARCHIVE_URL")"
  minio_sha="$(artifact_lock_required_sha256 "${lock_file}" "MINIO_ARCHIVE_SHA256")"
  minio_client_image="$(artifact_lock_required_digest_image "${lock_file}" "MINIO_CLIENT_IMAGE")"
  minio_client_url="$(artifact_lock_required_url "${lock_file}" "MINIO_CLIENT_ARCHIVE_URL")"
  minio_client_sha="$(artifact_lock_required_sha256 "${lock_file}" "MINIO_CLIENT_ARCHIVE_SHA256")"
  keycloak_image="$(artifact_lock_required_digest_image "${lock_file}" "KEYCLOAK_IMAGE")"
  keycloak_url="$(artifact_lock_required_url "${lock_file}" "KEYCLOAK_ARCHIVE_URL")"
  keycloak_sha="$(artifact_lock_required_sha256 "${lock_file}" "KEYCLOAK_ARCHIVE_SHA256")"
  juicefs_image="$(artifact_lock_required_helm_image "${lock_file}" "JUICEFS_CSI_IMAGE")"
  juicefs_url="$(artifact_lock_required_url "${lock_file}" "JUICEFS_CSI_ARCHIVE_URL")"
  juicefs_sha="$(artifact_lock_required_sha256 "${lock_file}" "JUICEFS_CSI_ARCHIVE_SHA256")"
  liveness_image="$(artifact_lock_required_helm_image "${lock_file}" "JUICEFS_CSI_LIVENESS_PROBE_IMAGE")"
  liveness_url="$(artifact_lock_required_url "${lock_file}" "JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_URL")"
  liveness_sha="$(artifact_lock_required_sha256 "${lock_file}" "JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_SHA256")"
  registrar_image="$(artifact_lock_required_helm_image "${lock_file}" "JUICEFS_CSI_NODE_DRIVER_REGISTRAR_IMAGE")"
  registrar_url="$(artifact_lock_required_url "${lock_file}" "JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_URL")"
  registrar_sha="$(artifact_lock_required_sha256 "${lock_file}" "JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_SHA256")"
  provisioner_image="$(artifact_lock_required_helm_image "${lock_file}" "JUICEFS_CSI_PROVISIONER_IMAGE")"
  provisioner_url="$(artifact_lock_required_url "${lock_file}" "JUICEFS_CSI_PROVISIONER_ARCHIVE_URL")"
  provisioner_sha="$(artifact_lock_required_sha256 "${lock_file}" "JUICEFS_CSI_PROVISIONER_ARCHIVE_SHA256")"
  resizer_image="$(artifact_lock_required_helm_image "${lock_file}" "JUICEFS_CSI_RESIZER_IMAGE")"
  resizer_url="$(artifact_lock_required_url "${lock_file}" "JUICEFS_CSI_RESIZER_ARCHIVE_URL")"
  resizer_sha="$(artifact_lock_required_sha256 "${lock_file}" "JUICEFS_CSI_RESIZER_ARCHIVE_SHA256")"
  rwx_check_image="$(artifact_lock_required_digest_image "${lock_file}" "RWX_CHECK_IMAGE")"
  rwx_check_url="$(artifact_lock_required_url "${lock_file}" "RWX_CHECK_ARCHIVE_URL")"
  rwx_check_sha="$(artifact_lock_required_sha256 "${lock_file}" "RWX_CHECK_ARCHIVE_SHA256")"
  local_openai_image="$(artifact_lock_required_digest_image "${lock_file}" "LOCAL_OPENAI_PROVIDER_IMAGE")"
  local_openai_url="$(artifact_lock_required_url "${lock_file}" "LOCAL_OPENAI_PROVIDER_ARCHIVE_URL")"
  local_openai_sha="$(artifact_lock_required_sha256 "${lock_file}" "LOCAL_OPENAI_PROVIDER_ARCHIVE_SHA256")"

  prepare_output_dir "${dir}"

  download_verified_artifact "K3S_BINARY_URL" "${k3s_url}" "${k3s_sha}" "${dir}/bin/k3s"
  download_verified_artifact "K3S_INSTALL_SCRIPT_URL" "${install_url}" "${install_sha}" "${dir}/scripts/install-k3s.sh"
  download_verified_artifact "K3S_AIRGAP_IMAGES_URL" "${airgap_url}" "${airgap_sha}" "${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst"
  download_verified_artifact "KUBECTL_BINARY_URL" "${kubectl_url}" "${kubectl_sha}" "${dir}/bin/kubectl"
  download_verified_artifact "HELM_BINARY_URL" "${helm_url}" "${helm_sha}" "${dir}/bin/helm"
  download_verified_artifact "JUICEFS_CSI_ARTIFACT_URL" "${csi_chart_url}" "${csi_chart_sha}" "${dir}/charts/juicefs-csi.tgz"
  download_verified_artifact "POSTGRES_ARCHIVE_URL" "${postgres_url}" "${postgres_sha}" "${dir}/images/oci/postgres.tar"
  download_verified_artifact "MINIO_ARCHIVE_URL" "${minio_url}" "${minio_sha}" "${dir}/images/oci/minio.tar"
  download_verified_artifact "MINIO_CLIENT_ARCHIVE_URL" "${minio_client_url}" "${minio_client_sha}" "${dir}/images/oci/minio-client.tar"
  download_verified_artifact "KEYCLOAK_ARCHIVE_URL" "${keycloak_url}" "${keycloak_sha}" "${dir}/images/oci/keycloak.tar"
  download_verified_artifact "JUICEFS_CSI_ARCHIVE_URL" "${juicefs_url}" "${juicefs_sha}" "${dir}/images/oci/juicefs-csi.tar"
  download_verified_artifact "JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_URL" "${liveness_url}" "${liveness_sha}" "${dir}/images/oci/juicefs-csi-liveness-probe.tar"
  download_verified_artifact "JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_URL" "${registrar_url}" "${registrar_sha}" "${dir}/images/oci/juicefs-csi-node-driver-registrar.tar"
  download_verified_artifact "JUICEFS_CSI_PROVISIONER_ARCHIVE_URL" "${provisioner_url}" "${provisioner_sha}" "${dir}/images/oci/juicefs-csi-provisioner.tar"
  download_verified_artifact "JUICEFS_CSI_RESIZER_ARCHIVE_URL" "${resizer_url}" "${resizer_sha}" "${dir}/images/oci/juicefs-csi-resizer.tar"
  download_verified_artifact "RWX_CHECK_ARCHIVE_URL" "${rwx_check_url}" "${rwx_check_sha}" "${dir}/images/oci/rwx-check.tar"
  download_verified_artifact "LOCAL_OPENAI_PROVIDER_ARCHIVE_URL" "${local_openai_url}" "${local_openai_sha}" "${dir}/images/oci/local-openai-provider.tar"
  chmod +x "${dir}/bin/k3s" "${dir}/scripts/install-k3s.sh" "${dir}/bin/kubectl" "${dir}/bin/helm"

  cat >"${dir}/scripts/import-images.sh" <<'EOF_IMPORT'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/import-images.sh [--dry-run] [--containerd-namespace k8s.io]

Imports OCI archives listed in images/images.lock from this offline cache into
the local k3s/containerd store with cached bin/k3s ctr. It performs no network access.
EOF_USAGE
}

containerd_namespace="${CONTAINERD_NAMESPACE:-k8s.io}"
dry_run=false

require_value() {
  local flag="$1"
  local value="${2-}"
  if [[ $# -lt 2 || -z "${value}" || "${value}" == --* ]]; then
    printf 'error: %s requires a value\n' "${flag}" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --containerd-namespace)
      require_value "$1" "${2-}"
      containerd_namespace="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cache_dir="$(cd "${script_dir}/.." && pwd)"
lock_file="${cache_dir}/images/images.lock"

[[ -f "${lock_file}" ]] || {
  printf 'error: images.lock not found at %s\n' "${lock_file}" >&2
  exit 1
}

cache_relative_archive_path() {
  local archive="$1"
  local cache_root parent_rel base parent_abs full_path resolved

  [[ -n "${archive}" ]] || {
    printf 'error: invalid images.lock archive path: empty paths are not allowed\n' >&2
    exit 1
  }
  [[ "${archive}" != /* ]] || {
    printf 'error: invalid images.lock archive path: absolute paths are not allowed\n' >&2
    exit 1
  }
  [[ "${archive}" != *"://"* ]] || {
    printf 'error: invalid images.lock archive path: URL-like paths are not allowed\n' >&2
    exit 1
  }
  case "${archive}" in
    ..|../*|*/..|*/../*)
      printf 'error: invalid images.lock archive path: parent traversal is not allowed\n' >&2
      exit 1
      ;;
  esac

  cache_root="$(cd "${cache_dir}" && pwd -P)" || {
    printf 'error: cache directory is not readable\n' >&2
    exit 1
  }
  parent_rel="$(dirname -- "${archive}")"
  base="$(basename -- "${archive}")"
  if [[ "${parent_rel}" == "." ]]; then
    parent_abs="${cache_root}"
  else
    parent_abs="$(cd "${cache_root}/${parent_rel}" && pwd -P)" || {
      printf 'error: archive directory is not inside this offline cache\n' >&2
      exit 1
    }
  fi

  case "${parent_abs}/" in
    "${cache_root}/"*) ;;
    *)
      printf 'error: images.lock archive path escapes this offline cache\n' >&2
      exit 1
      ;;
  esac

  full_path="${parent_abs}/${base}"
  if [[ -e "${full_path}" ]]; then
    resolved="$(realpath "${full_path}" 2>/dev/null || readlink -f "${full_path}" 2>/dev/null || true)"
    if [[ -n "${resolved}" ]]; then
      case "${resolved}" in
        "${cache_root}"|"${cache_root}/"*) ;;
        *)
          printf 'error: images.lock archive path escapes this offline cache\n' >&2
          exit 1
          ;;
      esac
      full_path="${resolved}"
    fi
  fi

  printf '%s\n' "${full_path}"
}

mapfile -t archives < <(awk '
  /^[[:space:]]*archive:[[:space:]]*/ {
    value=$0
    sub(/^[[:space:]]*archive:[[:space:]]*/, "", value)
    gsub(/^"|"$/, "", value)
    gsub(/^\047|\047$/, "", value)
    print value
  }
' "${lock_file}")

archive_paths=()
for archive in "${archives[@]}"; do
  archive_paths+=("$(cache_relative_archive_path "${archive}")")
done

if [[ "${#archives[@]}" -eq 0 ]]; then
  printf 'No OCI archives listed in %s\n' "${lock_file}"
  exit 0
fi

if [[ "${dry_run}" == "true" ]]; then
  printf 'Would import %d OCI archive(s) from %s into containerd namespace %s:\n' "${#archives[@]}" "${lock_file}" "${containerd_namespace}"
  for archive_path in "${archive_paths[@]}"; do
    printf '  %s\n' "${archive_path}"
  done
  exit 0
fi

cached_k3s="${cache_dir}/bin/k3s"
[[ -x "${cached_k3s}" ]] || {
  printf 'error: cached k3s is required at %s to import OCI archives. Run this with a p1-real offline cache, or rerun with --dry-run.\n' "${cached_k3s}" >&2
  exit 1
}

for archive_path in "${archive_paths[@]}"; do
  [[ -f "${archive_path}" ]] || {
    printf 'error: archive not found: %s\n' "${archive_path}" >&2
    exit 1
  }
  printf 'Importing %s into containerd namespace %s\n' "${archive_path}" "${containerd_namespace}"
  "${cached_k3s}" ctr -n "${containerd_namespace}" images import "${archive_path}"
done
EOF_IMPORT
  chmod +x "${dir}/scripts/import-images.sh"

  cp "${ROOT_DIR}/manifests/namespace/namespace.yaml" "${dir}/manifests/namespace-bootstrap/namespace.yaml"

  local k3s_sum install_sum airgap_sum kubectl_sum helm_sum import_sum namespace_sum csi_chart_sum postgres_sum minio_sum minio_client_sum keycloak_sum juicefs_sum
  local liveness_sum registrar_sum provisioner_sum resizer_sum rwx_check_sum local_openai_sum lock_sum manifest_sum
  k3s_sum="$(sha256_file "${dir}/bin/k3s")"
  install_sum="$(sha256_file "${dir}/scripts/install-k3s.sh")"
  airgap_sum="$(sha256_file "${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst")"
  kubectl_sum="$(sha256_file "${dir}/bin/kubectl")"
  helm_sum="$(sha256_file "${dir}/bin/helm")"
  import_sum="$(sha256_file "${dir}/scripts/import-images.sh")"
  namespace_sum="$(sha256_file "${dir}/manifests/namespace-bootstrap/namespace.yaml")"
  csi_chart_sum="$(sha256_file "${dir}/charts/juicefs-csi.tgz")"
  postgres_sum="$(sha256_file "${dir}/images/oci/postgres.tar")"
  minio_sum="$(sha256_file "${dir}/images/oci/minio.tar")"
  minio_client_sum="$(sha256_file "${dir}/images/oci/minio-client.tar")"
  keycloak_sum="$(sha256_file "${dir}/images/oci/keycloak.tar")"
  juicefs_sum="$(sha256_file "${dir}/images/oci/juicefs-csi.tar")"
  liveness_sum="$(sha256_file "${dir}/images/oci/juicefs-csi-liveness-probe.tar")"
  registrar_sum="$(sha256_file "${dir}/images/oci/juicefs-csi-node-driver-registrar.tar")"
  provisioner_sum="$(sha256_file "${dir}/images/oci/juicefs-csi-provisioner.tar")"
  resizer_sum="$(sha256_file "${dir}/images/oci/juicefs-csi-resizer.tar")"
  rwx_check_sum="$(sha256_file "${dir}/images/oci/rwx-check.tar")"
  local_openai_sum="$(sha256_file "${dir}/images/oci/local-openai-provider.tar")"

  cat >"${dir}/images/images.lock" <<EOF_LOCK
schemaVersion: agentsmith-lite.substrate.images/v1
images:
  - name: postgres
    image: ${postgres_image}
    archive: images/oci/postgres.tar
    sha256: ${postgres_sum}
  - name: minio
    image: ${minio_image}
    archive: images/oci/minio.tar
    sha256: ${minio_sum}
  - name: minio-client
    image: ${minio_client_image}
    archive: images/oci/minio-client.tar
    sha256: ${minio_client_sum}
  - name: keycloak
    image: ${keycloak_image}
    archive: images/oci/keycloak.tar
    sha256: ${keycloak_sum}
  - name: juicefs-csi
    image: ${juicefs_image}
    archive: images/oci/juicefs-csi.tar
    sha256: ${juicefs_sum}
  - name: juicefs-csi-liveness-probe
    image: ${liveness_image}
    archive: images/oci/juicefs-csi-liveness-probe.tar
    sha256: ${liveness_sum}
  - name: juicefs-csi-node-driver-registrar
    image: ${registrar_image}
    archive: images/oci/juicefs-csi-node-driver-registrar.tar
    sha256: ${registrar_sum}
  - name: juicefs-csi-provisioner
    image: ${provisioner_image}
    archive: images/oci/juicefs-csi-provisioner.tar
    sha256: ${provisioner_sum}
  - name: juicefs-csi-resizer
    image: ${resizer_image}
    archive: images/oci/juicefs-csi-resizer.tar
    sha256: ${resizer_sum}
  - name: rwx-check
    image: ${rwx_check_image}
    archive: images/oci/rwx-check.tar
    sha256: ${rwx_check_sum}
  - name: local-openai-provider
    image: ${local_openai_image}
    archive: images/oci/local-openai-provider.tar
    sha256: ${local_openai_sum}
EOF_LOCK
  lock_sum="$(sha256_file "${dir}/images/images.lock")"

  cat >"${dir}/manifest.yaml" <<EOF_MANIFEST
schemaVersion: agentsmith-lite.substrate.offline-cache/v1
cacheMode: p1-real
artifacts:
  - path: bin/k3s
    sha256: ${k3s_sum}
    kind: k3s-binary
  - path: scripts/install-k3s.sh
    sha256: ${install_sum}
    kind: k3s-install-script
  - path: images/k3s/k3s-airgap-images-amd64.tar.zst
    sha256: ${airgap_sum}
    kind: k3s-airgap-images
  - path: bin/kubectl
    sha256: ${kubectl_sum}
    kind: kubectl-binary
  - path: bin/helm
    sha256: ${helm_sum}
    kind: helm-binary
  - path: scripts/import-images.sh
    sha256: ${import_sum}
    kind: script
  - path: manifests/namespace-bootstrap/namespace.yaml
    sha256: ${namespace_sum}
    kind: manifest
  - path: images/images.lock
    sha256: ${lock_sum}
    kind: images-lock
  - path: charts/juicefs-csi.tgz
    sha256: ${csi_chart_sum}
    kind: juicefs-csi-artifact
  - path: images/oci/postgres.tar
    sha256: ${postgres_sum}
    kind: oci-archive
  - path: images/oci/minio.tar
    sha256: ${minio_sum}
    kind: oci-archive
  - path: images/oci/minio-client.tar
    sha256: ${minio_client_sum}
    kind: oci-archive
  - path: images/oci/keycloak.tar
    sha256: ${keycloak_sum}
    kind: oci-archive
  - path: images/oci/juicefs-csi.tar
    sha256: ${juicefs_sum}
    kind: oci-archive
  - path: images/oci/juicefs-csi-liveness-probe.tar
    sha256: ${liveness_sum}
    kind: oci-archive
  - path: images/oci/juicefs-csi-node-driver-registrar.tar
    sha256: ${registrar_sum}
    kind: oci-archive
  - path: images/oci/juicefs-csi-provisioner.tar
    sha256: ${provisioner_sum}
    kind: oci-archive
  - path: images/oci/juicefs-csi-resizer.tar
    sha256: ${resizer_sum}
    kind: oci-archive
  - path: images/oci/rwx-check.tar
    sha256: ${rwx_check_sum}
    kind: oci-archive
  - path: images/oci/local-openai-provider.tar
    sha256: ${local_openai_sum}
    kind: oci-archive
EOF_MANIFEST
  manifest_sum="$(sha256_file "${dir}/manifest.yaml")"

  cat >"${dir}/checksums.txt" <<EOF_SUMS
${manifest_sum}  manifest.yaml
${k3s_sum}  bin/k3s
${install_sum}  scripts/install-k3s.sh
${airgap_sum}  images/k3s/k3s-airgap-images-amd64.tar.zst
${kubectl_sum}  bin/kubectl
${helm_sum}  bin/helm
${import_sum}  scripts/import-images.sh
${namespace_sum}  manifests/namespace-bootstrap/namespace.yaml
${lock_sum}  images/images.lock
${csi_chart_sum}  charts/juicefs-csi.tgz
${postgres_sum}  images/oci/postgres.tar
${minio_sum}  images/oci/minio.tar
${minio_client_sum}  images/oci/minio-client.tar
${keycloak_sum}  images/oci/keycloak.tar
${juicefs_sum}  images/oci/juicefs-csi.tar
${liveness_sum}  images/oci/juicefs-csi-liveness-probe.tar
${registrar_sum}  images/oci/juicefs-csi-node-driver-registrar.tar
${provisioner_sum}  images/oci/juicefs-csi-provisioner.tar
${resizer_sum}  images/oci/juicefs-csi-resizer.tar
${rwx_check_sum}  images/oci/rwx-check.tar
${local_openai_sum}  images/oci/local-openai-provider.tar
EOF_SUMS

  validate_offline_cache "${dir}"
  info "wrote p1-real offline cache: ${dir}"
  info "note: install-offline.sh can run the cached p1-real chain through JuiceFS CSI Helm install, format bootstrap, PVC Bound wait, and local provider readiness"
}

if [[ -n "${artifact_lock}" ]]; then
  write_p1_real_cache "${artifact_lock}" "${output_dir}"
else
  write_p0_contract_cache "${output_dir}"
fi
