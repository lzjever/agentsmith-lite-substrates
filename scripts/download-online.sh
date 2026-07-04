#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
# shellcheck source=lib/offline.sh
source "${ROOT_DIR}/scripts/lib/offline.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: scripts/download-online.sh --output dist/offline-cache [--force]

Writes the P0 offline cache contract skeleton. This is intentionally not a real
offline install cache: it has no k3s binary, k3s airgap archive, kubectl binary,
or JuiceFS CSI artifact. p1-real caches are validated by install-offline.sh and
doctor.sh when supplied, but full mirroring is not implemented here yet.
EOF_USAGE
}

output_dir="dist/offline-cache"
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output_dir="${2:-}"
      shift 2
      ;;
    --force)
      force=true
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

if [[ -e "${output_dir}/manifest.yaml" && "${force}" != "true" ]]; then
  die "${output_dir}/manifest.yaml already exists; rerun with --force to overwrite"
fi

safe_remove_dir "${output_dir}"
mkdir -p "${output_dir}/images/oci" "${output_dir}/manifests/namespace-bootstrap" "${output_dir}/scripts" "${output_dir}/bin" "${output_dir}/charts"

cat >"${output_dir}/scripts/import-images.sh" <<'EOF_IMPORT'
#!/usr/bin/env bash
set -euo pipefail
printf 'P0 contract skeleton has no OCI archives to import and is not a real offline install cache.\n'
EOF_IMPORT
chmod +x "${output_dir}/scripts/import-images.sh"

cp "${ROOT_DIR}/manifests/namespace/namespace.yaml" "${output_dir}/manifests/namespace-bootstrap/namespace.yaml"

cat >"${output_dir}/images/images.lock" <<'EOF_LOCK'
schemaVersion: agentsmith-lite.substrate.images/v1
images: []
EOF_LOCK

import_sum="$(sha256_file "${output_dir}/scripts/import-images.sh")"
namespace_sum="$(sha256_file "${output_dir}/manifests/namespace-bootstrap/namespace.yaml")"
lock_sum="$(sha256_file "${output_dir}/images/images.lock")"

cat >"${output_dir}/manifest.yaml" <<EOF_MANIFEST
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
EOF_MANIFEST

manifest_sum="$(sha256_file "${output_dir}/manifest.yaml")"
cat >"${output_dir}/checksums.txt" <<EOF_SUMS
${manifest_sum}  manifest.yaml
${import_sum}  scripts/import-images.sh
${namespace_sum}  manifests/namespace-bootstrap/namespace.yaml
${lock_sum}  images/images.lock
EOF_SUMS

validate_offline_cache "${output_dir}"
info "wrote P0 offline cache contract skeleton: ${output_dir}"
info "note: this cache is not a real offline install cache; p1-real requires k3s, kubectl, k3s airgap images, dependency OCI archives, and a JuiceFS CSI artifact"
