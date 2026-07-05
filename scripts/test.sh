#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass_count=0

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "${pass_count}" "$*"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "${needle}" "${file}"; then
    fail "expected ${file} to contain: ${needle}"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq -- "${needle}" "${file}"; then
    fail "expected ${file} to redact: ${needle}"
  fi
}

first_line_number() {
  local file="$1"
  local needle="$2"
  grep -Fn -- "${needle}" "${file}" | head -n 1 | cut -d: -f1 || true
}

assert_line_order() {
  local file="$1"
  shift
  local previous=0
  local needle line
  for needle in "$@"; do
    line="$(first_line_number "${file}" "${needle}")"
    [[ -n "${line}" ]] || fail "expected ${file} to contain ordered line: ${needle}"
    [[ "${line}" -gt "${previous}" ]] || fail "expected ${needle} to appear after previous call in ${file}"
    previous="${line}"
  done
}

write_valid_env_pair() {
  local dir="$1"
  mkdir -p "${dir}"
  cat >"${dir}/substrate.env" <<'EOF_ENV'
SUBSTRATE_SCHEMA_VERSION=agentsmith-lite.substrate.env/v1
KUBECONFIG_PATH=
KUBE_CONTEXT=
KUBE_NAMESPACE=agentsmith
S3_ENDPOINT=http://minio.agentsmith.svc.cluster.local:9000
S3_REGION=us-east-1
S3_BUCKET=agentsmith-lite-files
S3_FORCE_PATH_STYLE=true
AUTH_MODE=builtin_admin
OIDC_ISSUER_URL=
OIDC_CLIENT_ID=agentsmith-lite
JUICEFS_VOLUME_NAME=agentsmith-lite-files
JUICEFS_BUCKET=s3://agentsmith-lite-files/agentsmith-lite/
JUICEFS_SECRET_NAME=agentsmith-lite-juicefs
JUICEFS_CSI_DRIVER=csi.juicefs.com
JUICEFS_STORAGE_CLASS=agentsmith-lite-juicefs-rwx
JUICEFS_PVC_NAME=agentsmith-lite-files
JUICEFS_MOUNT_ROOT=/agentsmith-lite
APP_PUBLIC_BASE_URL=https://agentsmith.example.com
APP_INGRESS_CLASS=
APP_TLS_SECRET_NAME=
REGISTRY_URL=
IMAGE_PULL_SECRET_NAME=
EOF_ENV
  cat >"${dir}/substrate.secrets.env" <<'EOF_SECRETS'
SUBSTRATE_SCHEMA_VERSION=agentsmith-lite.substrate.env/v1
POSTGRES_APP_URL=postgresql://agentsmith:postgres-secret-value@postgres.agentsmith.svc.cluster.local:5432/agentsmith_lite
APP_SESSION_SECRET=app-session-secret-value
S3_ACCESS_KEY=minio-access-key
S3_SECRET_KEY=minio-secret-value
JUICEFS_META_URL=postgresql://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta
BUILTIN_ADMIN_INITIAL_PASSWORD=admin-secret-value
OIDC_CLIENT_SECRET=
EOF_SECRETS
  chmod 0600 "${dir}/substrate.secrets.env"
}

replace_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp="${file}.tmp"
  awk -v wanted="${key}" -v replacement="${value}" '
    index($0, wanted "=") == 1 {
      print wanted "=" replacement
      next
    }
    { print }
  ' "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
}

write_config() {
  local file="$1"
  cat >"${file}" <<'EOF_CONFIG'
mode: self-hosted
kubernetes:
  distribution: k3s
  namespace: agentsmith
  kubeconfigOutput: out/kubeconfig
postgres:
  storageClass: local-path
  appDatabase: agentsmith_lite
  juicefsDatabase: juicefs_meta
objectStorage:
  provider: minio
  endpoint: http://minio.agentsmith.svc.cluster.local:9000
  region: us-east-1
  bucket: agentsmith-lite-files
juicefs:
  volumeName: agentsmith-lite-files
  storageClass: agentsmith-lite-juicefs-rwx
  pvcName: agentsmith-lite-files
auth:
  mode: builtin_admin
ingress:
  publicBaseUrl: https://agentsmith.example.com
  installDevIngress: true
offline:
  registry: registry.local:5000
EOF_CONFIG
}

write_existing_cloud_config() {
  local file="$1"
  cat >"${file}" <<'EOF_CONFIG'
mode: existing-cloud
kubernetes:
  namespace: agentsmith
  kubeconfigPath: out/kubeconfig
  context: production
postgres:
  appUrlFromEnv: POSTGRES_APP_URL
  juicefsMetaUrlFromEnv: JUICEFS_META_URL
objectStorage:
  provider: s3
  endpoint: https://s3.us-east-1.amazonaws.com
  region: us-east-1
  bucket: agentsmith-lite-files
  accessKeyFromEnv: S3_ACCESS_KEY
  secretKeyFromEnv: S3_SECRET_KEY
juicefs:
  volumeName: agentsmith-lite-files
  secretName: agentsmith-lite-juicefs
  csiDriver: csi.juicefs.com
  storageClass: agentsmith-lite-juicefs-rwx
  pvcName: agentsmith-lite-files
  mountRoot: /agentsmith-lite
auth:
  mode: builtin_admin
ingress:
  publicBaseUrl: https://agentsmith.example.com
EOF_CONFIG
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_offline_cache() {
  local dir="$1"
  mkdir -p "${dir}/images/oci" "${dir}/manifests/namespace-bootstrap" "${dir}/scripts"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "import-images dry-run\\n"\n' >"${dir}/scripts/import-images.sh"
  chmod +x "${dir}/scripts/import-images.sh"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: agentsmith\n' >"${dir}/manifests/namespace-bootstrap/namespace.yaml"
  printf 'placeholder oci archive\n' >"${dir}/images/oci/minio.tar"

  local import_sum namespace_sum image_sum lock_sum manifest_sum
  import_sum="$(sha256_file "${dir}/scripts/import-images.sh")"
  namespace_sum="$(sha256_file "${dir}/manifests/namespace-bootstrap/namespace.yaml")"
  image_sum="$(sha256_file "${dir}/images/oci/minio.tar")"
  cat >"${dir}/images/images.lock" <<EOF_LOCK
schemaVersion: agentsmith-lite.substrate.images/v1
images:
  - name: minio
    image: quay.io/minio/minio@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    archive: images/oci/minio.tar
    sha256: ${image_sum}
EOF_LOCK
  lock_sum="$(sha256_file "${dir}/images/images.lock")"
  cat >"${dir}/manifest.yaml" <<EOF_MANIFEST
schemaVersion: agentsmith-lite.substrate.offline-cache/v1
cacheMode: p0-contract
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
  - path: images/oci/minio.tar
    sha256: ${image_sum}
    kind: oci-archive
EOF_MANIFEST
  manifest_sum="$(sha256_file "${dir}/manifest.yaml")"
  cat >"${dir}/checksums.txt" <<EOF_SUMS
${manifest_sum}  manifest.yaml
${import_sum}  scripts/import-images.sh
${namespace_sum}  manifests/namespace-bootstrap/namespace.yaml
${lock_sum}  images/images.lock
${image_sum}  images/oci/minio.tar
EOF_SUMS
}

write_p1_offline_cache() {
  local dir="$1"
  local variant="${2:-valid}"
  mkdir -p "${dir}/bin" "${dir}/charts" "${dir}/images/k3s" "${dir}/images/oci" "${dir}/manifests/namespace-bootstrap" "${dir}/scripts"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${dir}/bin/k3s"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${dir}/bin/kubectl"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${dir}/bin/helm"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${dir}/scripts/install-k3s.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "import-images dry-run\\n"\n' >"${dir}/scripts/import-images.sh"
  chmod +x "${dir}/bin/k3s" "${dir}/bin/kubectl" "${dir}/bin/helm" "${dir}/scripts/install-k3s.sh" "${dir}/scripts/import-images.sh"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: agentsmith\n' >"${dir}/manifests/namespace-bootstrap/namespace.yaml"
  printf 'k3s airgap archive fixture\n' >"${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst"
  printf 'juicefs csi chart fixture\n' >"${dir}/charts/juicefs-csi.tgz"
  printf 'postgres oci archive fixture\n' >"${dir}/images/oci/postgres.tar"
  printf 'minio oci archive fixture\n' >"${dir}/images/oci/minio.tar"
  printf 'minio client oci archive fixture\n' >"${dir}/images/oci/minio-client.tar"
  printf 'juicefs csi oci archive fixture\n' >"${dir}/images/oci/juicefs-csi.tar"
  printf 'juicefs csi liveness probe oci archive fixture\n' >"${dir}/images/oci/juicefs-csi-liveness-probe.tar"
  printf 'juicefs csi node driver registrar oci archive fixture\n' >"${dir}/images/oci/juicefs-csi-node-driver-registrar.tar"
  printf 'juicefs csi provisioner oci archive fixture\n' >"${dir}/images/oci/juicefs-csi-provisioner.tar"
  printf 'juicefs csi resizer oci archive fixture\n' >"${dir}/images/oci/juicefs-csi-resizer.tar"

  local k3s_sum kubectl_sum helm_sum install_sum import_sum namespace_sum airgap_sum csi_chart_sum postgres_sum minio_sum minio_client_sum juicefs_sum
  local liveness_sum registrar_sum provisioner_sum resizer_sum lock_sum manifest_sum
  k3s_sum="$(sha256_file "${dir}/bin/k3s")"
  kubectl_sum="$(sha256_file "${dir}/bin/kubectl")"
  helm_sum="$(sha256_file "${dir}/bin/helm")"
  install_sum="$(sha256_file "${dir}/scripts/install-k3s.sh")"
  import_sum="$(sha256_file "${dir}/scripts/import-images.sh")"
  namespace_sum="$(sha256_file "${dir}/manifests/namespace-bootstrap/namespace.yaml")"
  airgap_sum="$(sha256_file "${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst")"
  csi_chart_sum="$(sha256_file "${dir}/charts/juicefs-csi.tgz")"
  postgres_sum="$(sha256_file "${dir}/images/oci/postgres.tar")"
  minio_sum="$(sha256_file "${dir}/images/oci/minio.tar")"
  minio_client_sum="$(sha256_file "${dir}/images/oci/minio-client.tar")"
  juicefs_sum="$(sha256_file "${dir}/images/oci/juicefs-csi.tar")"
  liveness_sum="$(sha256_file "${dir}/images/oci/juicefs-csi-liveness-probe.tar")"
  registrar_sum="$(sha256_file "${dir}/images/oci/juicefs-csi-node-driver-registrar.tar")"
  provisioner_sum="$(sha256_file "${dir}/images/oci/juicefs-csi-provisioner.tar")"
  resizer_sum="$(sha256_file "${dir}/images/oci/juicefs-csi-resizer.tar")"

  if [[ "${variant}" == "missing-image-sha" ]]; then
    cat >"${dir}/images/images.lock" <<EOF_LOCK
schemaVersion: agentsmith-lite.substrate.images/v1
images:
  - name: postgres
    image: docker.io/library/postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    archive: images/oci/postgres.tar
    sha256: ${postgres_sum}
  - name: minio
    image: quay.io/minio/minio@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    archive: images/oci/minio.tar
  - name: minio-client
    image: quay.io/minio/mc@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    archive: images/oci/minio-client.tar
    sha256: ${minio_client_sum}
  - name: juicefs-csi
    image: docker.io/juicedata/juicefs-csi-driver:v0.31.10@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    archive: images/oci/juicefs-csi.tar
    sha256: ${juicefs_sum}
EOF_LOCK
  else
    {
      cat <<EOF_LOCK
schemaVersion: agentsmith-lite.substrate.images/v1
images:
  - name: postgres
    image: docker.io/library/postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    archive: images/oci/postgres.tar
    sha256: ${postgres_sum}
  - name: minio
    image: quay.io/minio/minio@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    archive: images/oci/minio.tar
    sha256: ${minio_sum}
EOF_LOCK
      if [[ "${variant}" != "missing-minio-client" ]]; then
        cat <<EOF_LOCK
  - name: minio-client
    image: quay.io/minio/mc@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    archive: images/oci/minio-client.tar
    sha256: ${minio_client_sum}
EOF_LOCK
      fi
      cat <<EOF_LOCK
  - name: juicefs-csi
    image: docker.io/juicedata/juicefs-csi-driver:v0.31.10@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    archive: images/oci/juicefs-csi.tar
    sha256: ${juicefs_sum}
  - name: juicefs-csi-liveness-probe
    image: registry.k8s.io/sig-storage/livenessprobe:v2.12.0@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    archive: images/oci/juicefs-csi-liveness-probe.tar
    sha256: ${liveness_sum}
  - name: juicefs-csi-node-driver-registrar
    image: registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.9.0@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    archive: images/oci/juicefs-csi-node-driver-registrar.tar
    sha256: ${registrar_sum}
  - name: juicefs-csi-provisioner
    image: registry.k8s.io/sig-storage/csi-provisioner:v2.2.2@sha256:1111111111111111111111111111111111111111111111111111111111111111
    archive: images/oci/juicefs-csi-provisioner.tar
    sha256: ${provisioner_sum}
  - name: juicefs-csi-resizer
    image: registry.k8s.io/sig-storage/csi-resizer:v1.9.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
    archive: images/oci/juicefs-csi-resizer.tar
    sha256: ${resizer_sum}
EOF_LOCK
    } >"${dir}/images/images.lock"
  fi
  lock_sum="$(sha256_file "${dir}/images/images.lock")"

  {
    cat <<EOF_MANIFEST
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
EOF_MANIFEST
    if [[ "${variant}" != "missing-minio-client" ]]; then
      cat <<EOF_MANIFEST
  - path: images/oci/minio-client.tar
    sha256: ${minio_client_sum}
    kind: oci-archive
EOF_MANIFEST
    fi
    cat <<EOF_MANIFEST
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
EOF_MANIFEST
  } >"${dir}/manifest.yaml"
  manifest_sum="$(sha256_file "${dir}/manifest.yaml")"
  {
    cat <<EOF_SUMS
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
EOF_SUMS
    if [[ "${variant}" != "missing-minio-client" ]]; then
      cat <<EOF_SUMS
${minio_client_sum}  images/oci/minio-client.tar
EOF_SUMS
    fi
    cat <<EOF_SUMS
${juicefs_sum}  images/oci/juicefs-csi.tar
${liveness_sum}  images/oci/juicefs-csi-liveness-probe.tar
${registrar_sum}  images/oci/juicefs-csi-node-driver-registrar.tar
${provisioner_sum}  images/oci/juicefs-csi-provisioner.tar
${resizer_sum}  images/oci/juicefs-csi-resizer.tar
EOF_SUMS
  } >"${dir}/checksums.txt"
}

remove_manifest_artifact_entry() {
  local manifest_file="$1"
  local path="$2"
  local tmp="${manifest_file}.tmp"
  awk -v unwanted="${path}" '
    function flush() {
      if (block != "") {
        if (index(block, "path: " unwanted) == 0) {
          printf "%s", block
        }
        block=""
      }
    }
    /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
      flush()
      block=$0 "\n"
      next
    }
    block != "" {
      block=block $0 "\n"
      next
    }
    { print }
    END { flush() }
  ' "${manifest_file}" >"${tmp}"
  mv "${tmp}" "${manifest_file}"
}

refresh_manifest_checksum_entry() {
  local cache="$1"
  local manifest_sum tmp
  manifest_sum="$(sha256_file "${cache}/manifest.yaml")"
  tmp="${cache}/checksums.txt.tmp"
  awk -v sum="${manifest_sum}" '
    $2 == "manifest.yaml" {
      print sum "  manifest.yaml"
      next
    }
    { print }
  ' "${cache}/checksums.txt" >"${tmp}"
  mv "${tmp}" "${cache}/checksums.txt"
}

refresh_checksum_entry() {
  local cache="$1"
  local path="$2"
  local sum tmp
  sum="$(sha256_file "${cache}/${path}")"
  tmp="${cache}/checksums.txt.tmp"
  awk -v wanted="${path}" -v sum="${sum}" '
    $2 == wanted {
      print sum "  " wanted
      next
    }
    { print }
  ' "${cache}/checksums.txt" >"${tmp}"
  mv "${tmp}" "${cache}/checksums.txt"
}

refresh_manifest_artifact_checksum() {
  local cache="$1"
  local path="$2"
  local sum tmp
  sum="$(sha256_file "${cache}/${path}")"
  tmp="${cache}/manifest.yaml.tmp"
  awk -v wanted="${path}" -v sum="${sum}" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", value)
      in_wanted=(trim(value) == wanted)
      print
      next
    }
    in_wanted && /^[[:space:]]*sha256:[[:space:]]*/ {
      sub(/sha256:[[:space:]]*.*/, "sha256: " sum)
      in_wanted=0
      print
      next
    }
    { print }
  ' "${cache}/manifest.yaml" >"${tmp}"
  mv "${tmp}" "${cache}/manifest.yaml"
}

refresh_cache_artifacts() {
  local cache="$1"
  shift
  local path
  for path in "$@"; do
    refresh_checksum_entry "${cache}" "${path}"
    refresh_manifest_artifact_checksum "${cache}" "${path}"
  done
  refresh_manifest_checksum_entry "${cache}"
}

remove_checksum_entry() {
  local cache="$1"
  local path="$2"
  local tmp="${cache}/checksums.txt.tmp"
  awk -v unwanted="${path}" '$2 != unwanted { print }' "${cache}/checksums.txt" >"${tmp}"
  mv "${tmp}" "${cache}/checksums.txt"
}

replace_manifest_cache_mode() {
  local cache="$1"
  local mode="$2"
  local tmp="${cache}/manifest.yaml.tmp"
  awk -v mode="${mode}" '
    /^[[:space:]]*cacheMode:[[:space:]]*/ {
      print "cacheMode: " mode
      next
    }
    { print }
  ' "${cache}/manifest.yaml" >"${tmp}"
  mv "${tmp}" "${cache}/manifest.yaml"
}

replace_manifest_artifact_path_and_sha() {
  local cache="$1"
  local old_path="$2"
  local new_path="$3"
  local new_sha="$4"
  local tmp="${cache}/manifest.yaml.tmp"
  awk -v old_path="${old_path}" -v new_path="${new_path}" -v new_sha="${new_sha}" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    /^[[:space:]]*-[[:space:]]*path:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", value)
      in_wanted=(trim(value) == old_path)
      if (in_wanted) {
        sub(/path:[[:space:]]*.*/, "path: " new_path)
      }
      print
      next
    }
    in_wanted && /^[[:space:]]*sha256:[[:space:]]*/ {
      sub(/sha256:[[:space:]]*.*/, "sha256: " new_sha)
      in_wanted=0
      print
      next
    }
    { print }
  ' "${cache}/manifest.yaml" >"${tmp}"
  mv "${tmp}" "${cache}/manifest.yaml"
}

replace_images_lock_archive_and_sha() {
  local cache="$1"
  local old_archive="$2"
  local new_archive="$3"
  local new_sha="$4"
  local tmp="${cache}/images/images.lock.tmp"
  awk -v old_archive="${old_archive}" -v new_archive="${new_archive}" -v new_sha="${new_sha}" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    /^[[:space:]]*archive:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*archive:[[:space:]]*/, "", value)
      in_wanted=(trim(value) == old_archive)
      if (in_wanted) {
        sub(/archive:[[:space:]]*.*/, "archive: " new_archive)
      }
      print
      next
    }
    in_wanted && /^[[:space:]]*sha256:[[:space:]]*/ {
      sub(/sha256:[[:space:]]*.*/, "sha256: " new_sha)
      in_wanted=0
      print
      next
    }
    { print }
  ' "${cache}/images/images.lock" >"${tmp}"
  mv "${tmp}" "${cache}/images/images.lock"
}

remove_images_lock_archive_and_sha_for_name() {
  local cache="$1"
  local name="$2"
  local tmp="${cache}/images/images.lock.tmp"
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
      print
      next
    }
    in_wanted && /^[[:space:]]*(archive|sha256):[[:space:]]*/ {
      next
    }
    { print }
  ' "${cache}/images/images.lock" >"${tmp}"
  mv "${tmp}" "${cache}/images/images.lock"
}

remove_images_lock_entry_for_name() {
  local cache="$1"
  local name="$2"
  local tmp="${cache}/images/images.lock.tmp"
  awk -v wanted="${name}" '
    function trim(v) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^\047|\047$/, "", v)
      return v
    }
    function flush() {
      if (block != "") {
        if (entry_name != wanted) {
          printf "%s", block
        }
        block=""
        entry_name=""
      }
    }
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      flush()
      value=$0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", value)
      entry_name=trim(value)
      block=$0 "\n"
      next
    }
    block != "" {
      block=block $0 "\n"
      next
    }
    { print }
    END { flush() }
  ' "${cache}/images/images.lock" >"${tmp}"
  mv "${tmp}" "${cache}/images/images.lock"
}

replace_images_lock_image_ref() {
  local cache="$1"
  local name="$2"
  local image_ref="$3"
  local tmp="${cache}/images/images.lock.tmp"
  awk -v wanted="${name}" -v replacement="${image_ref}" '
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
      print
      next
    }
    in_wanted && /^[[:space:]]*image:[[:space:]]*/ {
      sub(/image:[[:space:]]*.*/, "image: " replacement)
      in_wanted=0
      print
      next
    }
    { print }
  ' "${cache}/images/images.lock" >"${tmp}"
  mv "${tmp}" "${cache}/images/images.lock"
}

file_url() {
  local file="$1"
  printf 'file://%s' "${file}"
}

write_p1_install_chain_fakes() {
  local cache="$1"

  cat >"${cache}/scripts/install-k3s.sh" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -euo pipefail
: "${CALL_LOG:?CALL_LOG is required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cache_dir="$(cd "${script_dir}/.." && pwd)"
{
  printf 'install-k3s\n'
  printf 'INSTALL_K3S_SKIP_DOWNLOAD=%s\n' "${INSTALL_K3S_SKIP_DOWNLOAD:-}"
  printf 'INSTALL_K3S_EXEC=%s\n' "${INSTALL_K3S_EXEC:-}"
  printf 'INSTALL_K3S_BIN_DIR=%s\n' "${INSTALL_K3S_BIN_DIR:-}"
  printf 'K3S_BINARY_PATH=%s\n' "${K3S_BINARY_PATH:-}"
} >>"${CALL_LOG}"
[[ "${INSTALL_K3S_SKIP_DOWNLOAD:-}" == "true" ]] || exit 31
[[ "${K3S_BINARY_PATH:-}" == "${cache_dir}/bin/k3s" ]] || exit 32
case "${INSTALL_K3S_EXEC:-}" in
  *"server --write-kubeconfig "*" --write-kubeconfig-mode 600"*) ;;
  *) exit 33 ;;
esac
EOF_INSTALL

  cat >"${cache}/scripts/import-images.sh" <<'EOF_IMPORT'
#!/usr/bin/env bash
set -euo pipefail
: "${CALL_LOG:?CALL_LOG is required}"
printf 'import-images args=%s\n' "$*" >>"${CALL_LOG}"
case " $* " in
  *" --dry-run "*) exit 41 ;;
esac
EOF_IMPORT

  cat >"${cache}/bin/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
: "${CALL_LOG:?CALL_LOG is required}"
printf 'kubectl %s\n' "$*" >>"${CALL_LOG}"
case "$*" in
  *postgresql://*|*postgres://*|*postgres-secret-value*|*juicefs-secret-value*|*minio-secret-value*|*minio-access-key*|*S3_SECRET_KEY*) exit 54 ;;
esac
is_exec=false
has_stdin=false
for arg in "$@"; do
  if [[ "${arg}" == "exec" ]]; then
    is_exec=true
  elif [[ "${arg}" == "-i" ]]; then
    has_stdin=true
  fi
done
if [[ "${is_exec}" == "true" && "${has_stdin}" == "true" ]]; then
  : "${EXEC_STDIN_DIR:?EXEC_STDIN_DIR is required for kubectl exec -i fakes}"
  mkdir -p "${EXEC_STDIN_DIR}"
  umask 077
  stdin_file="$(mktemp "${EXEC_STDIN_DIR}/kubectl-exec-stdin.XXXXXX.sql")"
  cat >"${stdin_file}"
  chmod 0600 "${stdin_file}"
  bytes="$(wc -c <"${stdin_file}" | tr -d '[:space:]')"
  printf 'kubectl exec stdin bytes=%s file=%s\n' "${bytes}" "${stdin_file}" >>"${CALL_LOG}"
fi
previous=""
for arg in "$@"; do
  if [[ "${previous}" == "-f" ]]; then
    [[ -f "${arg}" ]] || exit 51
  fi
  previous="${arg}"
done
case "$*" in
  *" get pvc agentsmith-lite-files -o jsonpath={.status.phase}"*)
    printf '%s\n' "${JUICEFS_FAKE_PVC_PHASE:-Bound}"
    ;;
  *"logs job/agentsmith-lite-juicefs-format"*)
    case "${JUICEFS_FAKE_FORMAT_MODE:-ok}" in
      mismatch)
        printf 'agentsmith-lite-juicefs-format: existing JuiceFS volume mismatch: bucket\n'
        ;;
      *)
        printf 'agentsmith-lite-juicefs-format: ok\n'
        ;;
    esac
    ;;
esac
exit 0
EOF_KUBECTL

  cat >"${cache}/bin/helm" <<'EOF_HELM'
#!/usr/bin/env bash
set -euo pipefail
: "${CALL_LOG:?CALL_LOG is required}"
printf 'helm %s\n' "$*" >>"${CALL_LOG}"
case "$*" in
  *postgresql://*|*postgres://*|*postgres-secret-value*|*juicefs-secret-value*|*minio-secret-value*|*minio-access-key*|*S3_SECRET_KEY*|*JUICEFS_META_URL*) exit 64 ;;
esac
chart_seen=false
values_seen=false
previous=""
for arg in "$@"; do
  if [[ "${arg}" == */charts/juicefs-csi.tgz ]]; then
    [[ -f "${arg}" ]] || exit 61
    chart_seen=true
  fi
  if [[ "${previous}" == "-f" ]]; then
    [[ -f "${arg}" ]] || exit 62
    case "$(basename "${arg}")" in
      juicefs-csi-values.yaml) values_seen=true ;;
      *) exit 63 ;;
    esac
  fi
  previous="${arg}"
done
[[ "${chart_seen}" == "true" ]] || exit 65
[[ "${values_seen}" == "true" ]] || exit 66
[[ " $* " == *" upgrade --install juicefs-csi-driver "* ]] || exit 67
[[ " $* " == *" --namespace kube-system "* ]] || exit 68
[[ " $* " == *" --create-namespace "* ]] || exit 69
[[ " $* " == *" --wait "* ]] || exit 70
[[ " $* " == *" --timeout "* ]] || exit 71
exit 0
EOF_HELM

  chmod +x "${cache}/scripts/install-k3s.sh" "${cache}/scripts/import-images.sh" "${cache}/bin/kubectl" "${cache}/bin/helm"
  refresh_cache_artifacts "${cache}" "scripts/install-k3s.sh" "scripts/import-images.sh" "bin/kubectl" "bin/helm"
}

write_forbidden_path_bin() {
  local dir="$1"
  mkdir -p "${dir}"
  local tool
  for tool in kubectl curl wget docker helm; do
    cat >"${dir}/${tool}" <<'EOF_FORBIDDEN'
#!/usr/bin/env bash
set -euo pipefail
: "${FORBIDDEN_LOG:?FORBIDDEN_LOG is required}"
printf 'forbidden:%s\n' "$(basename "$0")" >>"${FORBIDDEN_LOG}"
exit 99
EOF_FORBIDDEN
    chmod +x "${dir}/${tool}"
  done

  cat >"${dir}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
exit 0
EOF_PSQL
  chmod +x "${dir}/psql"
}

write_downloader_fixtures() {
  local dir="$1"
  mkdir -p "${dir}"
  printf '#!/usr/bin/env sh\nprintf "k3s fixture\\n"\n' >"${dir}/k3s"
  printf '#!/usr/bin/env sh\nprintf "install k3s fixture\\n"\n' >"${dir}/install-k3s.sh"
  printf 'k3s airgap archive fixture from downloader\n' >"${dir}/k3s-airgap-images-amd64.tar.zst"
  printf '#!/usr/bin/env sh\nprintf "kubectl fixture\\n"\n' >"${dir}/kubectl"
  printf '#!/usr/bin/env sh\nprintf "helm fixture\\n"\n' >"${dir}/helm"
  printf 'juicefs csi chart fixture from downloader\n' >"${dir}/juicefs-csi.tgz"
  printf 'postgres oci archive fixture from downloader\n' >"${dir}/postgres.tar"
  printf 'minio oci archive fixture from downloader\n' >"${dir}/minio.tar"
  printf 'minio client oci archive fixture from downloader\n' >"${dir}/minio-client.tar"
  printf 'juicefs csi oci archive fixture from downloader\n' >"${dir}/juicefs-csi.tar"
  printf 'juicefs csi liveness probe oci archive fixture from downloader\n' >"${dir}/juicefs-csi-liveness-probe.tar"
  printf 'juicefs csi node driver registrar oci archive fixture from downloader\n' >"${dir}/juicefs-csi-node-driver-registrar.tar"
  printf 'juicefs csi provisioner oci archive fixture from downloader\n' >"${dir}/juicefs-csi-provisioner.tar"
  printf 'juicefs csi resizer oci archive fixture from downloader\n' >"${dir}/juicefs-csi-resizer.tar"
}

write_artifact_lock() {
  local fixtures="$1"
  local lock_file="$2"
  local variant="${3:-valid}"
  local k3s_sha install_sha airgap_sha kubectl_sha helm_sha csi_chart_sha postgres_sha minio_sha minio_client_sha juicefs_sha
  local liveness_sha registrar_sha provisioner_sha resizer_sha
  k3s_sha="$(sha256_file "${fixtures}/k3s")"
  install_sha="$(sha256_file "${fixtures}/install-k3s.sh")"
  airgap_sha="$(sha256_file "${fixtures}/k3s-airgap-images-amd64.tar.zst")"
  kubectl_sha="$(sha256_file "${fixtures}/kubectl")"
  helm_sha="$(sha256_file "${fixtures}/helm")"
  csi_chart_sha="$(sha256_file "${fixtures}/juicefs-csi.tgz")"
  postgres_sha="$(sha256_file "${fixtures}/postgres.tar")"
  minio_sha="$(sha256_file "${fixtures}/minio.tar")"
  minio_client_sha="$(sha256_file "${fixtures}/minio-client.tar")"
  juicefs_sha="$(sha256_file "${fixtures}/juicefs-csi.tar")"
  liveness_sha="$(sha256_file "${fixtures}/juicefs-csi-liveness-probe.tar")"
  registrar_sha="$(sha256_file "${fixtures}/juicefs-csi-node-driver-registrar.tar")"
  provisioner_sha="$(sha256_file "${fixtures}/juicefs-csi-provisioner.tar")"
  resizer_sha="$(sha256_file "${fixtures}/juicefs-csi-resizer.tar")"

  local postgres_image="docker.io/library/postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  local minio_client_image="quay.io/minio/mc@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  local juicefs_csi_image="docker.io/juicedata/juicefs-csi-driver:v0.31.10@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  local liveness_image="registry.k8s.io/sig-storage/livenessprobe:v2.12.0@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  if [[ "${variant}" == "mutable-image" ]]; then
    postgres_image="docker.io/library/postgres:16"
  fi
  if [[ "${variant}" == "mutable-minio-client-image" ]]; then
    minio_client_image="quay.io/minio/mc:latest"
  fi
  if [[ "${variant}" == "mutable-csi-sidecar-image" ]]; then
    liveness_image="registry.k8s.io/sig-storage/livenessprobe:latest"
  fi
  if [[ "${variant}" == "untagged-helm-image" ]]; then
    juicefs_csi_image="docker.io/juicedata/juicefs-csi-driver@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  fi
  if [[ "${variant}" == "sha-mismatch" ]]; then
    k3s_sha="0000000000000000000000000000000000000000000000000000000000000000"
  fi

  cat >"${lock_file}" <<EOF_LOCK
K3S_BINARY_URL=$(file_url "${fixtures}/k3s")
K3S_BINARY_SHA256=${k3s_sha}
K3S_INSTALL_SCRIPT_URL=$(file_url "${fixtures}/install-k3s.sh")
K3S_INSTALL_SCRIPT_SHA256=${install_sha}
K3S_AIRGAP_IMAGES_URL=$(file_url "${fixtures}/k3s-airgap-images-amd64.tar.zst")
K3S_AIRGAP_IMAGES_SHA256=${airgap_sha}
KUBECTL_BINARY_URL=$(file_url "${fixtures}/kubectl")
KUBECTL_BINARY_SHA256=${kubectl_sha}
HELM_BINARY_URL=$(file_url "${fixtures}/helm")
HELM_BINARY_SHA256=${helm_sha}
JUICEFS_CSI_ARTIFACT_URL=$(file_url "${fixtures}/juicefs-csi.tgz")
JUICEFS_CSI_ARTIFACT_SHA256=${csi_chart_sha}
POSTGRES_IMAGE=${postgres_image}
POSTGRES_ARCHIVE_URL=$(file_url "${fixtures}/postgres.tar")
POSTGRES_ARCHIVE_SHA256=${postgres_sha}
MINIO_IMAGE=quay.io/minio/minio@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MINIO_ARCHIVE_URL=$(file_url "${fixtures}/minio.tar")
MINIO_ARCHIVE_SHA256=${minio_sha}
MINIO_CLIENT_IMAGE=${minio_client_image}
MINIO_CLIENT_ARCHIVE_URL=$(file_url "${fixtures}/minio-client.tar")
MINIO_CLIENT_ARCHIVE_SHA256=${minio_client_sha}
JUICEFS_CSI_IMAGE=${juicefs_csi_image}
JUICEFS_CSI_ARCHIVE_URL=$(file_url "${fixtures}/juicefs-csi.tar")
JUICEFS_CSI_ARCHIVE_SHA256=${juicefs_sha}
JUICEFS_CSI_LIVENESS_PROBE_IMAGE=${liveness_image}
JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_URL=$(file_url "${fixtures}/juicefs-csi-liveness-probe.tar")
JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_SHA256=${liveness_sha}
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_IMAGE=registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.9.0@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_URL=$(file_url "${fixtures}/juicefs-csi-node-driver-registrar.tar")
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_SHA256=${registrar_sha}
JUICEFS_CSI_PROVISIONER_IMAGE=registry.k8s.io/sig-storage/csi-provisioner:v2.2.2@sha256:1111111111111111111111111111111111111111111111111111111111111111
JUICEFS_CSI_PROVISIONER_ARCHIVE_URL=$(file_url "${fixtures}/juicefs-csi-provisioner.tar")
JUICEFS_CSI_PROVISIONER_ARCHIVE_SHA256=${provisioner_sha}
JUICEFS_CSI_RESIZER_IMAGE=registry.k8s.io/sig-storage/csi-resizer:v1.9.0@sha256:2222222222222222222222222222222222222222222222222222222222222222
JUICEFS_CSI_RESIZER_ARCHIVE_URL=$(file_url "${fixtures}/juicefs-csi-resizer.tar")
JUICEFS_CSI_RESIZER_ARCHIVE_SHA256=${resizer_sha}
EOF_LOCK

  if [[ "${variant}" == "missing-key" ]]; then
    local tmp="${lock_file}.tmp"
    grep -v '^KUBECTL_BINARY_SHA256=' "${lock_file}" >"${tmp}"
    mv "${tmp}" "${lock_file}"
  fi
  if [[ "${variant}" == "missing-minio-client-key" ]]; then
    local tmp="${lock_file}.tmp"
    grep -v '^MINIO_CLIENT_IMAGE=' "${lock_file}" >"${tmp}"
    mv "${tmp}" "${lock_file}"
  fi
  if [[ "${variant}" == "missing-csi-sidecar-key" ]]; then
    local tmp="${lock_file}.tmp"
    grep -v '^JUICEFS_CSI_LIVENESS_PROBE_IMAGE=' "${lock_file}" >"${tmp}"
    mv "${tmp}" "${lock_file}"
  fi
  if [[ "${variant}" == "mutable-minio-client-image" ]]; then
    replace_env_value "${lock_file}" "MINIO_CLIENT_IMAGE" "quay.io/minio/mc:latest"
  fi
}

test_validate_env_split_and_redaction() {
  local dir="${TMP_DIR}/env-ok"
  local out="${TMP_DIR}/validate-ok.out"
  write_valid_env_pair "${dir}"
  "${ROOT_DIR}/scripts/validate-env.sh" --env "${dir}/substrate.env" --secrets "${dir}/substrate.secrets.env" >"${out}" 2>&1
  assert_contains "${out}" "validated substrate env contract"
  assert_contains "${out}" "secret boundary"
  assert_contains "${out}" "fingerprint="
  assert_not_contains "${out}" "postgres-secret-value"
  assert_not_contains "${out}" "app-session-secret-value"
  assert_not_contains "${out}" "minio-secret-value"
  assert_not_contains "${out}" "admin-secret-value"
  pass "S1 env/secrets contract accepts split files and redacts substrate/CSI secrets"
}

test_validate_env_rejects_secret_leak() {
  local dir="${TMP_DIR}/env-leak"
  local out="${TMP_DIR}/validate-leak.out"
  write_valid_env_pair "${dir}"
  printf 'S3_SECRET_KEY=leaked-secret-value\n' >>"${dir}/substrate.env"
  if "${ROOT_DIR}/scripts/validate-env.sh" --env "${dir}/substrate.env" --secrets "${dir}/substrate.secrets.env" >"${out}" 2>&1; then
    fail "validate-env accepted a secret key in substrate.env"
  fi
  assert_contains "${out}" "secret key S3_SECRET_KEY is not allowed in non-secret env"
  assert_not_contains "${out}" "leaked-secret-value"
  pass "S1 env/secrets contract rejects secret keys in substrate.env"
}

test_validate_env_rejects_loose_secret_mode() {
  local dir="${TMP_DIR}/env-mode"
  local out="${TMP_DIR}/validate-mode.out"
  write_valid_env_pair "${dir}"
  chmod 0644 "${dir}/substrate.secrets.env"
  if "${ROOT_DIR}/scripts/validate-env.sh" --env "${dir}/substrate.env" --secrets "${dir}/substrate.secrets.env" >"${out}" 2>&1; then
    fail "validate-env accepted group/world-readable substrate.secrets.env"
  fi
  assert_contains "${out}" "secret env permissions must not allow group/world access"
  assert_not_contains "${out}" "minio-secret-value"
  pass "S1 env/secrets contract rejects loose secret file permissions"
}

test_offline_install_validates_cache_without_network() {
  local cache="${TMP_DIR}/offline-cache"
  local config="${TMP_DIR}/substrates.yaml"
  local output="${TMP_DIR}/offline-out"
  local out="${TMP_DIR}/install-offline.out"
  write_offline_cache "${cache}"
  write_config "${config}"
  "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1
  test -f "${output}/substrate.env" || fail "install-offline did not write substrate.env"
  test -f "${output}/substrate.secrets.env" || fail "install-offline did not write substrate.secrets.env"
  test "$(stat -c '%a' "${output}/substrate.secrets.env")" = "600" || fail "install-offline did not chmod substrate.secrets.env to 0600"
  assert_contains "${out}" "offline cache contract validated"
  assert_contains "${out}" "P0 static cache skeleton"
  pass "S2 substrate offline path validates cache and writes env contract without network"
}

test_offline_cache_rejects_public_download_contract() {
  local cache="${TMP_DIR}/offline-cache-public-url"
  local config="${TMP_DIR}/substrates-public.yaml"
  local output="${TMP_DIR}/offline-public-out"
  local out="${TMP_DIR}/install-offline-public.out"
  local leaked_url="https://registry-1.docker.io/v2/"
  write_offline_cache "${cache}"
  write_config "${config}"
  printf '\npublicDownloadUrl: %s\n' "${leaked_url}" >>"${cache}/manifest.yaml"
  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a public download URL in offline cache manifest"
  fi
  assert_contains "${out}" "public download references are not allowed"
  assert_contains "${out}" "manifest.yaml"
  assert_not_contains "${out}" "${leaked_url}"
  pass "S2 offline-cache contract rejects public download references"
}

test_offline_cache_rejects_public_download_references_in_checksums() {
  local cache="${TMP_DIR}/offline-cache-checksums-url"
  local config="${TMP_DIR}/substrates-checksums-url.yaml"
  local output="${TMP_DIR}/offline-checksums-url-out"
  local out="${TMP_DIR}/install-offline-checksums-url.out"
  local leaked_url="https://downloads.example.invalid/offline-cache.tgz"
  write_offline_cache "${cache}"
  write_config "${config}"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  %s\n' "${leaked_url}" >>"${cache}/checksums.txt"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a public download URL in offline cache checksums"
  fi
  assert_contains "${out}" "public download references are not allowed"
  assert_contains "${out}" "checksums.txt"
  assert_not_contains "${out}" "${leaked_url}"
  pass "S2 offline-cache contract rejects public download references in checksums.txt"
}

test_offline_cache_rejects_manifest_artifact_path_escape_without_reading_outside() {
  local cache="${TMP_DIR}/offline-cache-manifest-path-escape"
  local outside="${TMP_DIR}/outside.txt"
  local out="${TMP_DIR}/manifest-path-escape.out"
  local outside_sum
  write_offline_cache "${cache}"
  printf 'outside cache sentinel\n' >"${outside}"
  outside_sum="$(sha256_file "${outside}")"
  replace_manifest_artifact_path_and_sha "${cache}" "images/oci/minio.tar" "../outside.txt" "${outside_sum}"

  if bash -c 'set -euo pipefail; source "$1/scripts/lib/offline.sh"; validate_manifest_artifact_checksums "$2"' _ "${ROOT_DIR}" "${cache}" >"${out}" 2>&1; then
    fail "offline manifest artifact checksum validation read a cache-escaped artifact"
  fi
  assert_contains "${out}" "manifest artifact path"
  pass "S2 offline-cache contract rejects manifest artifact path escape before reading outside cache"
}

test_offline_cache_rejects_checksums_path_escape() {
  local cache="${TMP_DIR}/offline-cache-checksums-path-escape"
  local config="${TMP_DIR}/substrates-checksums-path-escape.yaml"
  local output="${TMP_DIR}/offline-checksums-path-escape-out"
  local outside="${TMP_DIR}/outside.txt"
  local out="${TMP_DIR}/install-offline-checksums-path-escape.out"
  local outside_sum
  write_offline_cache "${cache}"
  write_config "${config}"
  printf 'outside checksum sentinel\n' >"${outside}"
  outside_sum="$(sha256_file "${outside}")"
  printf '%s  ../outside.txt\n' "${outside_sum}" >>"${cache}/checksums.txt"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a checksums.txt path escape"
  fi
  assert_contains "${out}" "checksums path"
  pass "S2 offline-cache contract rejects checksums.txt path escape"
}

test_p1_real_offline_cache_rejects_images_lock_archive_path_escape() {
  local cache="${TMP_DIR}/offline-cache-p1-images-lock-path-escape"
  local config="${TMP_DIR}/substrates-p1-images-lock-path-escape.yaml"
  local output="${TMP_DIR}/offline-p1-images-lock-path-escape-out"
  local outside="${TMP_DIR}/outside.tar"
  local out="${TMP_DIR}/install-offline-p1-images-lock-path-escape.out"
  local outside_sum
  write_p1_offline_cache "${cache}"
  write_config "${config}"
  printf 'outside archive sentinel\n' >"${outside}"
  outside_sum="$(sha256_file "${outside}")"
  replace_images_lock_archive_and_sha "${cache}" "images/oci/minio.tar" "../outside.tar" "${outside_sum}"
  refresh_checksum_entry "${cache}" "images/images.lock"
  refresh_manifest_artifact_checksum "${cache}" "images/images.lock"
  refresh_manifest_checksum_entry "${cache}"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted an images.lock archive path escape"
  fi
  assert_contains "${out}" "images.lock archive path"
  pass "S5 p1-real offline-cache contract rejects images.lock archive path escape"
}

test_offline_cache_scans_urls_before_cache_mode_errors_without_leaking() {
  local cache="${TMP_DIR}/offline-cache-cachemode-url"
  local config="${TMP_DIR}/substrates-cachemode-url.yaml"
  local output="${TMP_DIR}/offline-cachemode-url-out"
  local out="${TMP_DIR}/install-offline-cachemode-url.out"
  local leaked_url="https://downloads.example.invalid/cache-mode"
  write_offline_cache "${cache}"
  write_config "${config}"
  replace_manifest_cache_mode "${cache}" "${leaked_url}"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a URL-valued cacheMode"
  fi
  assert_contains "${out}" "public download references are not allowed"
  assert_contains "${out}" "manifest.yaml"
  assert_not_contains "${out}" "${leaked_url}"
  pass "S2 offline-cache contract scans URLs before cacheMode errors and redacts URL values"
}

test_offline_cache_rejects_url_suffix_fields_with_file_urls() {
  local cache="${TMP_DIR}/offline-cache-artifact-url"
  local config="${TMP_DIR}/substrates-artifact-url.yaml"
  local output="${TMP_DIR}/offline-artifact-url-out"
  local out="${TMP_DIR}/install-offline-artifact-url.out"
  local leaked_url="file:///tmp/x"
  write_offline_cache "${cache}"
  write_config "${config}"
  printf '\nartifactUrl: %s\n' "${leaked_url}" >>"${cache}/manifest.yaml"
  refresh_manifest_checksum_entry "${cache}"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted an artifactUrl field in offline cache manifest"
  fi
  assert_contains "${out}" "URL fields are not allowed"
  assert_contains "${out}" "manifest.yaml"
  assert_not_contains "${out}" "${leaked_url}"
  pass "S2 offline-cache contract rejects URL-suffix fields even when values are file URLs"
}

test_p1_real_offline_cache_requires_artifacts_and_archive_sha() {
  local cache="${TMP_DIR}/offline-cache-p1"
  local config="${TMP_DIR}/substrates-p1.yaml"
  local output="${TMP_DIR}/offline-p1-out"
  local out="${TMP_DIR}/install-offline-p1.out"
  write_p1_offline_cache "${cache}"
  write_config "${config}"
  "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1
  assert_contains "${out}" "offline cache contract validated (p1-real)"
  assert_contains "${out}" "validated p1-real cache contract"
  pass "S5 p1-real offline-cache contract requires k3s, kubectl, airgap, CSI, dependency images, and archive sha"
}

test_p1_real_offline_cache_requires_cached_helm() {
  local cache="${TMP_DIR}/offline-cache-p1-missing-helm"
  local config="${TMP_DIR}/substrates-p1-missing-helm.yaml"
  local output="${TMP_DIR}/offline-p1-missing-helm-out"
  local out="${TMP_DIR}/install-offline-p1-missing-helm.out"
  write_p1_offline_cache "${cache}"
  write_config "${config}"
  remove_manifest_artifact_entry "${cache}/manifest.yaml" "bin/helm"
  refresh_manifest_checksum_entry "${cache}"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a p1-real cache missing bin/helm"
  fi
  assert_contains "${out}" "missing required p1-real artifact bin/helm with kind helm-binary"
  pass "P6.5 p1-real offline-cache contract requires cached Helm binary"
}

test_p1_real_offline_cache_requires_csi_sidecar_archives_and_lock_entries() {
  local config="${TMP_DIR}/substrates-p1-missing-csi-sidecar.yaml"
  local spec name archive cache output out
  write_config "${config}"

  for spec in \
    "juicefs-csi-liveness-probe|images/oci/juicefs-csi-liveness-probe.tar" \
    "juicefs-csi-node-driver-registrar|images/oci/juicefs-csi-node-driver-registrar.tar" \
    "juicefs-csi-provisioner|images/oci/juicefs-csi-provisioner.tar" \
    "juicefs-csi-resizer|images/oci/juicefs-csi-resizer.tar"
  do
    IFS='|' read -r name archive <<<"${spec}"
    cache="${TMP_DIR}/offline-cache-p1-missing-${name}"
    output="${TMP_DIR}/offline-p1-missing-${name}-out"
    out="${TMP_DIR}/install-offline-p1-missing-${name}.out"
    write_p1_offline_cache "${cache}"
    remove_images_lock_entry_for_name "${cache}" "${name}"
    refresh_cache_artifacts "${cache}" "images/images.lock"

    if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
      fail "install-offline accepted a p1-real cache missing ${name} images.lock entry"
    fi
    assert_contains "${out}" "p1-real images.lock is missing dependency image entry: ${name}"

    cache="${TMP_DIR}/offline-cache-p1-missing-${name}-manifest"
    output="${TMP_DIR}/offline-p1-missing-${name}-manifest-out"
    out="${TMP_DIR}/install-offline-p1-missing-${name}-manifest.out"
    write_p1_offline_cache "${cache}"
    remove_manifest_artifact_entry "${cache}/manifest.yaml" "${archive}"
    refresh_manifest_checksum_entry "${cache}"

    if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
      fail "install-offline accepted a p1-real cache missing ${archive} from manifest artifacts"
    fi
    assert_contains "${out}" "missing required p1-real artifact ${archive} with kind oci-archive"
  done

  pass "P6.5 p1-real offline-cache contract requires CSI sidecar archives and lock entries"
}

test_p1_real_offline_cache_requires_minio_client_oci_archive() {
  local cache="${TMP_DIR}/offline-cache-p1-missing-minio-client"
  local config="${TMP_DIR}/substrates-p1-missing-minio-client.yaml"
  local output="${TMP_DIR}/offline-p1-missing-minio-client-out"
  local out="${TMP_DIR}/install-offline-p1-missing-minio-client.out"
  write_p1_offline_cache "${cache}" "missing-minio-client"
  write_config "${config}"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a p1-real cache missing the minio-client OCI archive"
  fi
  assert_contains "${out}" "missing required p1-real artifact images/oci/minio-client.tar with kind oci-archive"
  pass "S5 p1-real offline-cache contract requires cached minio-client OCI archive"
}

test_p1_real_offline_cache_requires_minio_client_images_lock_archive_sha() {
  local cache="${TMP_DIR}/offline-cache-p1-minio-client-lock-archive-sha"
  local config="${TMP_DIR}/substrates-p1-minio-client-lock-archive-sha.yaml"
  local output="${TMP_DIR}/offline-p1-minio-client-lock-archive-sha-out"
  local out="${TMP_DIR}/install-offline-p1-minio-client-lock-archive-sha.out"
  write_p1_offline_cache "${cache}"
  write_config "${config}"
  remove_images_lock_archive_and_sha_for_name "${cache}" "minio-client"
  refresh_cache_artifacts "${cache}" "images/images.lock"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a p1-real minio-client images.lock entry without archive/sha256"
  fi
  assert_contains "${out}" "images.lock entry minio-client is missing archive"
  pass "S5 p1-real offline-cache contract requires minio-client images.lock archive and sha"
}

test_p1_real_offline_cache_rejects_mutable_minio_client_image_ref() {
  local cache="${TMP_DIR}/offline-cache-p1-mutable-minio-client"
  local config="${TMP_DIR}/substrates-p1-mutable-minio-client.yaml"
  local output="${TMP_DIR}/offline-p1-mutable-minio-client-out"
  local out="${TMP_DIR}/install-offline-p1-mutable-minio-client.out"
  write_p1_offline_cache "${cache}"
  write_config "${config}"
  replace_images_lock_image_ref "${cache}" "minio-client" "quay.io/minio/mc:latest"
  refresh_cache_artifacts "${cache}" "images/images.lock"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a mutable minio-client image reference"
  fi
  assert_contains "${out}" "images.lock image is not digest-pinned"
  assert_contains "${out}" "quay.io/minio/mc:latest"
  pass "S5 p1-real offline-cache contract requires digest-pinned minio-client image"
}

test_p0_contract_offline_install_non_dry_run_still_fails() {
  local cache="${TMP_DIR}/offline-cache-p0-live"
  local config="${TMP_DIR}/substrates-p0-live.yaml"
  local output="${TMP_DIR}/offline-p0-live-out"
  local out="${TMP_DIR}/install-offline-p0-live.out"
  write_offline_cache "${cache}"
  write_config "${config}"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" >"${out}" 2>&1; then
    fail "install-offline performed a non-dry-run install from a p0-contract cache"
  fi
  assert_contains "${out}" "cannot perform live offline install from a P0 static cache skeleton"
  pass "P1 offline installer still rejects p0-contract caches outside dry-run"
}

test_p1_real_offline_install_dry_run_skips_cluster_mutation() {
  local cache="${TMP_DIR}/offline-cache-p1-dry-run-no-mutate"
  local config="${TMP_DIR}/substrates-p1-dry-run-no-mutate.yaml"
  local output="${TMP_DIR}/offline-p1-dry-run-no-mutate-out"
  local out="${TMP_DIR}/install-offline-p1-dry-run-no-mutate.out"
  local call_log="${TMP_DIR}/p1-dry-run-call.log"
  write_p1_offline_cache "${cache}"
  write_p1_install_chain_fakes "${cache}"
  write_config "${config}"

  CALL_LOG="${call_log}" "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1
  if [[ -s "${call_log}" ]]; then
    fail "p1-real dry-run called cached mutation artifacts"
  fi
  assert_contains "${out}" "dry-run: validated p1-real cache contract; skipped cluster mutation"
  pass "P1 offline installer dry-run validates p1-real cache without cluster mutation"
}

test_p1_real_offline_install_non_dry_run_runs_cached_chain() {
  local cache="${TMP_DIR}/offline-cache-p1-live"
  local config="${TMP_DIR}/substrates-p1-live.yaml"
  local output="${TMP_DIR}/offline-p1-live-out"
  local out="${TMP_DIR}/install-offline-p1-live.out"
  local call_log="${TMP_DIR}/p1-live-call.log"
  local forbidden_bin="${TMP_DIR}/p1-live-path-bin"
  local forbidden_log="${TMP_DIR}/p1-live-forbidden.log"
  local airgap_dir="${TMP_DIR}/p1-live-airgap"
  local exec_stdin_dir="${TMP_DIR}/p1-live-exec-stdin"
  local report="${output}/doctor-report.json"
  local rendered="${output}/rendered/offline-install"
  write_p1_offline_cache "${cache}"
  write_p1_install_chain_fakes "${cache}"
  write_forbidden_path_bin "${forbidden_bin}"
  write_config "${config}"

  CALL_LOG="${call_log}" \
    EXEC_STDIN_DIR="${exec_stdin_dir}" \
    FORBIDDEN_LOG="${forbidden_log}" \
    K3S_AIRGAP_DIR="${airgap_dir}" \
    POSTGRES_PASSWORD="postgres-secret-value" \
    JUICEFS_META_PASSWORD="juicefs-secret-value" \
    PATH="${forbidden_bin}:${PATH}" \
    "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" >"${out}" 2>&1 || {
      printf '%s\n' "install-offline output:" >&2
      sed -n '1,220p' "${out}" >&2
      fail "p1-real non-dry-run install did not complete"
    }

  [[ ! -s "${forbidden_log}" ]] || fail "install-offline used a forbidden PATH/public-network tool: $(<"${forbidden_log}")"
  test -f "${output}/substrate.env" || fail "install-offline did not write substrate.env"
  test -f "${output}/substrate.secrets.env" || fail "install-offline did not write substrate.secrets.env"
  test "$(stat -c '%a' "${output}/substrate.secrets.env")" = "600" || fail "install-offline did not chmod substrate.secrets.env to 0600"
  test -f "${rendered}/juicefs-secret.yaml" || fail "install-offline did not render JuiceFS Secret"
  test "$(stat -c '%a' "${rendered}/juicefs-secret.yaml")" = "600" || fail "install-offline did not keep rendered JuiceFS Secret owner-only"
  test -f "${rendered}/postgres-secret.yaml" || fail "install-offline did not render Postgres Secret"
  test "$(stat -c '%a' "${rendered}/postgres-secret.yaml")" = "600" || fail "install-offline did not keep rendered Postgres Secret owner-only"
  test -f "${rendered}/minio-secret.yaml" || fail "install-offline did not render MinIO Secret"
  test "$(stat -c '%a' "${rendered}/minio-secret.yaml")" = "600" || fail "install-offline did not keep rendered MinIO Secret owner-only"
  test -f "${rendered}/minio-bucket-init-job.yaml" || fail "install-offline did not render MinIO bucket init Job"
  test -f "${rendered}/juicefs-format-job.yaml" || fail "install-offline did not render JuiceFS format Job"
  test -f "${rendered}/juicefs-csi-values.yaml" || fail "install-offline did not render JuiceFS CSI Helm values"
  assert_contains "${rendered}/postgres-secret.yaml" "name: agentsmith-lite-postgres"
  assert_contains "${rendered}/postgres-secret.yaml" "username:"
  assert_contains "${rendered}/postgres-secret.yaml" "password:"
  assert_contains "${rendered}/postgres-secret.yaml" "database:"
  assert_contains "${rendered}/postgres-secret.yaml" "juicefsUsername:"
  assert_contains "${rendered}/postgres-secret.yaml" "juicefsPassword:"
  assert_contains "${rendered}/postgres-secret.yaml" "juicefsDatabase:"
  assert_contains "${rendered}/minio-secret.yaml" "name: agentsmith-lite-minio"
  assert_contains "${rendered}/minio-secret.yaml" "access-key:"
  assert_contains "${rendered}/minio-secret.yaml" "secret-key:"
  assert_not_contains "${rendered}/minio-secret.yaml" "minio-access-key"
  assert_not_contains "${rendered}/minio-secret.yaml" "minio-secret-value"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" "name: agentsmith-lite-minio-bucket-init"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" "image: quay.io/minio/mc@sha256:"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" "name: MINIO_ROOT_USER"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" "name: MINIO_ROOT_PASSWORD"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" "secretKeyRef:"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" "key: access-key"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" "key: secret-key"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" "config.json"
  assert_contains "${rendered}/minio-bucket-init-job.yaml" 'mc --config-dir "$MC_CONFIG_DIR" mb --ignore-existing'
  assert_not_contains "${rendered}/minio-bucket-init-job.yaml" 'mc alias set agentsmith-minio "$S3_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"'
  assert_not_contains "${rendered}/minio-bucket-init-job.yaml" '"$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"'
  assert_not_contains "${rendered}/minio-bucket-init-job.yaml" "S3_SECRET_KEY"
  assert_not_contains "${rendered}/minio-bucket-init-job.yaml" "minio-access-key"
  assert_not_contains "${rendered}/minio-bucket-init-job.yaml" "minio-secret-value"
  assert_contains "${rendered}/juicefs-format-job.yaml" "name: agentsmith-lite-juicefs-format"
  assert_contains "${rendered}/juicefs-format-job.yaml" "image: docker.io/juicedata/juicefs-csi-driver:v0.31.10@sha256:"
  assert_contains "${rendered}/juicefs-format-job.yaml" "name: JUICEFS_VOLUME_NAME"
  assert_contains "${rendered}/juicefs-format-job.yaml" "name: JUICEFS_META_URL"
  assert_contains "${rendered}/juicefs-format-job.yaml" "name: JUICEFS_BUCKET"
  assert_contains "${rendered}/juicefs-format-job.yaml" "name: S3_ACCESS_KEY"
  assert_contains "${rendered}/juicefs-format-job.yaml" "name: S3_SECRET_KEY"
  assert_contains "${rendered}/juicefs-format-job.yaml" "secretKeyRef:"
  assert_contains "${rendered}/juicefs-format-job.yaml" "key: metaurl"
  assert_contains "${rendered}/juicefs-format-job.yaml" "key: bucket"
  assert_contains "${rendered}/juicefs-format-job.yaml" "juicefs format"
  assert_contains "${rendered}/juicefs-format-job.yaml" '--bucket "$JUICEFS_BUCKET"'
  assert_contains "${rendered}/juicefs-format-job.yaml" "JFS_NO_CHECK_OBJECT_STORAGE=1"
  assert_not_contains "${rendered}/juicefs-format-job.yaml" "--access-key"
  assert_not_contains "${rendered}/juicefs-format-job.yaml" "--secret-key"
  assert_not_contains "${rendered}/juicefs-format-job.yaml" "postgresql://juicefs:"
  assert_not_contains "${rendered}/juicefs-format-job.yaml" "postgres-secret-value"
  assert_not_contains "${rendered}/juicefs-format-job.yaml" "juicefs-secret-value"
  assert_not_contains "${rendered}/juicefs-format-job.yaml" "minio-access-key"
  assert_not_contains "${rendered}/juicefs-format-job.yaml" "minio-secret-value"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "driverName: csi.juicefs.com"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "repository: docker.io/juicedata/juicefs-csi-driver"
  assert_contains "${rendered}/juicefs-csi-values.yaml" 'tag: "v0.31.10@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"'
  assert_contains "${rendered}/juicefs-csi-values.yaml" "livenessProbeImage:"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "repository: registry.k8s.io/sig-storage/livenessprobe"
  assert_contains "${rendered}/juicefs-csi-values.yaml" 'tag: "v2.12.0@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"'
  assert_contains "${rendered}/juicefs-csi-values.yaml" "nodeDriverRegistrarImage:"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "repository: registry.k8s.io/sig-storage/csi-node-driver-registrar"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "csiProvisionerImage:"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "repository: registry.k8s.io/sig-storage/csi-provisioner"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "csiResizerImage:"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "repository: registry.k8s.io/sig-storage/csi-resizer"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "dashboard:"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "snapshot:"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "storageClasses:"
  assert_contains "${rendered}/juicefs-csi-values.yaml" "enabled: false"
  assert_not_contains "${rendered}/juicefs-csi-values.yaml" "postgresql://juicefs:"
  assert_not_contains "${rendered}/juicefs-csi-values.yaml" "JUICEFS_META_URL"
  assert_not_contains "${rendered}/juicefs-csi-values.yaml" "S3_SECRET_KEY"
  assert_not_contains "${rendered}/juicefs-csi-values.yaml" "postgres-secret-value"
  assert_not_contains "${rendered}/juicefs-csi-values.yaml" "juicefs-secret-value"
  assert_not_contains "${rendered}/juicefs-csi-values.yaml" "minio-access-key"
  assert_not_contains "${rendered}/juicefs-csi-values.yaml" "minio-secret-value"

  assert_line_order "${call_log}" \
    "install-k3s" \
    "import-images args=" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${cache}/manifests/namespace-bootstrap/namespace.yaml" \
    "helm --kubeconfig ${output}/kubeconfig --context agentsmith-lite upgrade --install juicefs-csi-driver ${cache}/charts/juicefs-csi.tgz --namespace kube-system --create-namespace --wait --timeout 180s -f ${rendered}/juicefs-csi-values.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/postgres-secret.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/postgres.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith rollout status statefulset/postgres --timeout=180s" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith exec -i statefulset/postgres -- sh -c psql -v ON_ERROR_STOP=1 -U \"\${POSTGRES_USER}\" -d postgres" \
    "kubectl exec stdin bytes=" \
    "POSTGRES_PASSWORD postgres.agentsmith.svc.cluster.local 5432 agentsmith agentsmith_lite" \
    "JUICEFS_META_PASSWORD postgres.agentsmith.svc.cluster.local 5432 juicefs juicefs_meta" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/minio-secret.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/minio.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith rollout status statefulset/minio --timeout=180s" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/minio-bucket-init-job.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith wait --for=condition=complete job/agentsmith-lite-minio-bucket-init --timeout=120s" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite delete -f ${rendered}/minio-bucket-init-job.yaml --ignore-not-found=true" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/juicefs-secret.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/juicefs-format-job.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith wait --for=condition=complete job/agentsmith-lite-juicefs-format --timeout=120s" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith logs job/agentsmith-lite-juicefs-format" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith delete -f ${rendered}/juicefs-format-job.yaml --ignore-not-found=true" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/juicefs-storageclass-pvc.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith wait --for=jsonpath={.status.phase}=Bound pvc/agentsmith-lite-files --timeout=180s" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite get namespace agentsmith"
  assert_contains "${call_log}" "helm --kubeconfig ${output}/kubeconfig --context agentsmith-lite upgrade --install juicefs-csi-driver ${cache}/charts/juicefs-csi.tgz"
  assert_contains "${call_log}" "-Atc \"select 1\""
  assert_contains "${call_log}" "INSTALL_K3S_SKIP_DOWNLOAD=true"
  assert_contains "${call_log}" "INSTALL_K3S_EXEC=server --write-kubeconfig ${output}/kubeconfig --write-kubeconfig-mode 600"
  assert_contains "${call_log}" "K3S_BINARY_PATH=${cache}/bin/k3s"
  local exec_stdin_files=()
  local exec_stdin_file bootstrap_stdin_file=""
  mapfile -t exec_stdin_files < <(find "${exec_stdin_dir}" -type f -name 'kubectl-exec-stdin.*.sql' -print | sort)
  [[ "${#exec_stdin_files[@]}" -eq 3 ]] || fail "expected bootstrap plus app/JuiceFS database verification exec stdin captures, got ${#exec_stdin_files[@]}"
  for exec_stdin_file in "${exec_stdin_files[@]}"; do
    test "$(stat -c '%a' "${exec_stdin_file}")" = "600" || fail "captured exec stdin SQL was not owner-only"
    assert_not_contains "${exec_stdin_file}" "postgresql://"
    assert_not_contains "${exec_stdin_file}" "postgres://"
    if grep -Fq "CREATE DATABASE" "${exec_stdin_file}"; then
      bootstrap_stdin_file="${exec_stdin_file}"
    else
      test "$(stat -c '%s' "${exec_stdin_file}")" = "0" || fail "database verification exec stdin should not carry SQL or secrets"
    fi
  done
  [[ -n "${bootstrap_stdin_file}" ]] || fail "kubectl exec -i did not receive bootstrap SQL on stdin"
  assert_contains "${bootstrap_stdin_file}" "CREATE DATABASE"
  assert_contains "${bootstrap_stdin_file}" "agentsmith_lite"
  assert_contains "${bootstrap_stdin_file}" "juicefs_meta"
  assert_contains "${bootstrap_stdin_file}" "postgres-secret-value"
  assert_contains "${bootstrap_stdin_file}" "juicefs-secret-value"
  test -f "${airgap_dir}/k3s-airgap-images-amd64.tar.zst" || fail "install-offline did not copy k3s airgap archive into K3S_AIRGAP_DIR"
  cmp -s "${cache}/images/k3s/k3s-airgap-images-amd64.tar.zst" "${airgap_dir}/k3s-airgap-images-amd64.tar.zst" \
    || fail "copied k3s airgap archive differs from cached artifact"

  assert_not_contains "${rendered}/postgres.yaml" "image: postgres:16"
  assert_not_contains "${rendered}/minio.yaml" "image: minio/minio:"
  assert_contains "${rendered}/postgres.yaml" "image: docker.io/library/postgres@sha256:"
  assert_contains "${rendered}/postgres.yaml" "name: JUICEFS_META_PASSWORD"
  assert_contains "${rendered}/postgres.yaml" "key: juicefsPassword"
  assert_contains "${rendered}/minio.yaml" "image: quay.io/minio/minio@sha256:"
  assert_contains "${out}" "doctor reported partial"
  assert_not_contains "${out}" "postgres-secret-value"
  assert_not_contains "${out}" "juicefs-secret-value"
  assert_not_contains "${out}" "minio-access-key"
  assert_not_contains "${out}" "minio-secret-value"
  assert_not_contains "${call_log}" "postgres-secret-value"
  assert_not_contains "${call_log}" "juicefs-secret-value"
  assert_not_contains "${call_log}" "minio-access-key"
  assert_not_contains "${call_log}" "minio-secret-value"
  assert_not_contains "${call_log}" "S3_SECRET_KEY"
  assert_not_contains "${call_log}" "JUICEFS_META_URL="
  assert_not_contains "${call_log}" "postgresql://"
  assert_not_contains "${call_log}" "postgres://"
  assert_not_contains "${report}" "postgres-secret-value"
  assert_not_contains "${report}" "juicefs-secret-value"
  assert_not_contains "${report}" "minio-access-key"
  assert_not_contains "${report}" "minio-secret-value"
  assert_contains "${report}" "live JuiceFS PVC phase is Bound"
  pass "P1 offline installer non-dry-run executes cached k3s/import/kubectl chain without public network tools"
}

test_juicefs_format_job_renders_digest_pinned_image_and_secret_refs() {
  local env_dir="${TMP_DIR}/juicefs-format-env"
  local output="${TMP_DIR}/juicefs-format-job.yaml"
  local out="${TMP_DIR}/juicefs-format-render.out"
  local image="docker.io/juicedata/juicefs-csi-driver:v0.31.10@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  write_valid_env_pair "${env_dir}"

  bash -c 'set -euo pipefail; source "$1/scripts/lib/juicefs.sh"; render_juicefs_format_job "$2" "$3" "$1/manifests/juicefs-csi" "$4" "$5"' \
    _ "${ROOT_DIR}" "${env_dir}/substrate.env" "${env_dir}/substrate.secrets.env" "${output}" "${image}" >"${out}" 2>&1

  assert_contains "${output}" "image: ${image}"
  assert_contains "${output}" "name: agentsmith-lite-juicefs-format"
  assert_contains "${output}" "name: JUICEFS_VOLUME_NAME"
  assert_contains "${output}" "name: JUICEFS_META_URL"
  assert_contains "${output}" "name: JUICEFS_BUCKET"
  assert_contains "${output}" "valueFrom:"
  assert_contains "${output}" "secretKeyRef:"
  assert_contains "${output}" "name: agentsmith-lite-juicefs"
  assert_contains "${output}" "key: name"
  assert_contains "${output}" "key: metaurl"
  assert_contains "${output}" "key: bucket"
  assert_contains "${output}" "key: access-key"
  assert_contains "${output}" "key: secret-key"
  assert_contains "${output}" "juicefs format"
  assert_contains "${output}" '--storage s3'
  assert_contains "${output}" '--bucket "$JUICEFS_BUCKET"'
  assert_contains "${output}" "JFS_NO_CHECK_OBJECT_STORAGE=1"
  assert_not_contains "${output}" "--access-key"
  assert_not_contains "${output}" "--secret-key"
  assert_not_contains "${output}" "postgresql://juicefs:"
  assert_not_contains "${output}" "juicefs-secret-value"
  assert_not_contains "${output}" "minio-access-key"
  assert_not_contains "${output}" "minio-secret-value"
  assert_not_contains "${out}" "juicefs-secret-value"
  pass "JuiceFS format Job renders digest-pinned CSI image, secret refs, and complete format parameters"
}

test_p1_real_offline_install_fails_on_juicefs_format_mismatch_before_pvc() {
  local cache="${TMP_DIR}/offline-cache-p1-format-mismatch"
  local config="${TMP_DIR}/substrates-p1-format-mismatch.yaml"
  local output="${TMP_DIR}/offline-p1-format-mismatch-out"
  local out="${TMP_DIR}/install-offline-p1-format-mismatch.out"
  local call_log="${TMP_DIR}/p1-format-mismatch-call.log"
  local airgap_dir="${TMP_DIR}/p1-format-mismatch-airgap"
  local exec_stdin_dir="${TMP_DIR}/p1-format-mismatch-exec-stdin"
  write_p1_offline_cache "${cache}"
  write_p1_install_chain_fakes "${cache}"
  write_config "${config}"

  if CALL_LOG="${call_log}" \
    EXEC_STDIN_DIR="${exec_stdin_dir}" \
    K3S_AIRGAP_DIR="${airgap_dir}" \
    JUICEFS_FAKE_FORMAT_MODE="mismatch" \
    POSTGRES_PASSWORD="postgres-secret-value" \
    JUICEFS_META_PASSWORD="juicefs-secret-value" \
    "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" >"${out}" 2>&1; then
    fail "install-offline accepted a mismatched existing JuiceFS volume"
  fi

  assert_contains "${out}" "existing JuiceFS volume mismatch"
  assert_not_contains "${out}" "juicefs-secret-value"
  assert_not_contains "${out}" "minio-secret-value"
  assert_contains "${call_log}" "logs job/agentsmith-lite-juicefs-format"
  assert_not_contains "${call_log}" "apply -f ${output}/rendered/offline-install/juicefs-storageclass-pvc.yaml"
  assert_not_contains "${call_log}" "juicefs-secret-value"
  assert_not_contains "${call_log}" "minio-secret-value"
  pass "P1 offline installer fails JuiceFS format mismatch before applying PVC contract"
}

test_p1_real_offline_install_rejects_invalid_cache_before_mutation() {
  local cache="${TMP_DIR}/offline-cache-p1-invalid-before-mutate"
  local config="${TMP_DIR}/substrates-p1-invalid-before-mutate.yaml"
  local output="${TMP_DIR}/offline-p1-invalid-before-mutate-out"
  local out="${TMP_DIR}/install-offline-p1-invalid-before-mutate.out"
  local call_log="${TMP_DIR}/p1-invalid-before-mutate-call.log"
  write_p1_offline_cache "${cache}"
  write_p1_install_chain_fakes "${cache}"
  write_config "${config}"
  replace_images_lock_image_ref "${cache}" "postgres" "docker.io/library/postgres:16"
  refresh_cache_artifacts "${cache}" "images/images.lock"

  if CALL_LOG="${call_log}" "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" >"${out}" 2>&1; then
    fail "install-offline accepted an invalid p1-real cache before non-dry-run mutation"
  fi
  [[ ! -s "${call_log}" ]] || fail "install-offline mutated before rejecting invalid p1-real cache"
  assert_contains "${out}" "images.lock image is not digest-pinned"
  pass "P1 offline installer rejects invalid cache before cached mutation chain starts"
}

test_minio_bucket_init_job_keeps_credentials_out_of_mc_argv() {
  local env_dir="${TMP_DIR}/minio-bucket-init-env"
  local output="${TMP_DIR}/minio-bucket-init-job.yaml"
  local out="${TMP_DIR}/minio-bucket-init-render.out"
  local image="quay.io/minio/mc@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  write_valid_env_pair "${env_dir}"

  bash -c 'set -euo pipefail; source "$1/scripts/lib/minio.sh"; render_minio_bucket_init_job "$2" "$1/manifests/minio" "$3" "$4"' \
    _ "${ROOT_DIR}" "${env_dir}/substrate.env" "${output}" "${image}" >"${out}" 2>&1

  assert_contains "${output}" "name: MINIO_ROOT_USER"
  assert_contains "${output}" "name: MINIO_ROOT_PASSWORD"
  assert_contains "${output}" "secretKeyRef:"
  assert_contains "${output}" 'mc --config-dir "$MC_CONFIG_DIR" mb --ignore-existing'
  assert_contains "${output}" "config.json"
  assert_not_contains "${output}" 'mc alias set agentsmith-minio "$S3_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"'
  assert_not_contains "${output}" '"$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"'
  assert_not_contains "${output}" "S3_ACCESS_KEY"
  assert_not_contains "${output}" "S3_SECRET_KEY"
  assert_not_contains "${output}" "minio-access-key"
  assert_not_contains "${output}" "minio-secret-value"
  pass "MinIO bucket init keeps raw credentials out of mc argv and rendered logs"
}

test_p1_real_offline_install_rejects_mismatched_postgres_urls_before_mutation() {
  local cache="${TMP_DIR}/offline-cache-p1-mismatched-postgres"
  local config="${TMP_DIR}/substrates-p1-mismatched-postgres.yaml"
  local output="${TMP_DIR}/offline-p1-mismatched-postgres-out"
  local out="${TMP_DIR}/install-offline-p1-mismatched-postgres.out"
  local call_log="${TMP_DIR}/p1-mismatched-postgres-call.log"
  write_p1_offline_cache "${cache}"
  write_p1_install_chain_fakes "${cache}"
  write_config "${config}"

  if POSTGRES_APP_URL="postgresql://agentsmith:postgres-secret-value@postgres.agentsmith.svc.cluster.local:5432/agentsmith_lite" \
    JUICEFS_META_URL="postgresql://juicefs:juicefs-secret-value@other-postgres.agentsmith.svc.cluster.local:5432/juicefs_meta" \
    CALL_LOG="${call_log}" \
    "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" >"${out}" 2>&1; then
    fail "install-offline accepted mismatched self-hosted Postgres URL hosts"
  fi
  [[ ! -s "${call_log}" ]] || fail "install-offline mutated before rejecting mismatched Postgres URLs"
  assert_contains "${out}" "self-hosted Postgres URLs must use the same host"
  assert_not_contains "${out}" "postgres-secret-value"
  assert_not_contains "${out}" "juicefs-secret-value"
  pass "P1 offline installer rejects mismatched self-hosted Postgres URLs before mutation"
}

test_p1_real_offline_install_rejects_invalid_postgres_url_before_mutation() {
  local cache="${TMP_DIR}/offline-cache-p1-invalid-postgres-url"
  local config="${TMP_DIR}/substrates-p1-invalid-postgres-url.yaml"
  local output="${TMP_DIR}/offline-p1-invalid-postgres-url-out"
  local out="${TMP_DIR}/install-offline-p1-invalid-postgres-url.out"
  local call_log="${TMP_DIR}/p1-invalid-postgres-url-call.log"
  write_p1_offline_cache "${cache}"
  write_p1_install_chain_fakes "${cache}"
  write_config "${config}"

  if POSTGRES_APP_URL="postgresql://agentsmith:postgres-secret-value@postgres.agentsmith.svc.cluster.local:5432" \
    JUICEFS_META_URL="postgresql://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta" \
    CALL_LOG="${call_log}" \
    "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" >"${out}" 2>&1; then
    fail "install-offline accepted an invalid self-hosted Postgres URL"
  fi
  [[ ! -s "${call_log}" ]] || fail "install-offline mutated before rejecting invalid Postgres URL"
  assert_contains "${out}" "invalid self-hosted POSTGRES_APP_URL"
  assert_not_contains "${out}" "postgres-secret-value"
  assert_not_contains "${out}" "juicefs-secret-value"
  pass "P1 offline installer rejects invalid self-hosted Postgres URLs before mutation"
}

test_existing_cloud_offline_install_does_not_mutate_self_hosted_postgres() {
  local cache="${TMP_DIR}/offline-cache-existing-cloud"
  local config="${TMP_DIR}/substrates-existing-cloud.yaml"
  local output="${TMP_DIR}/offline-existing-cloud-out"
  local out="${TMP_DIR}/install-offline-existing-cloud.out"
  local call_log="${TMP_DIR}/existing-cloud-call.log"
  local stub_bin="${TMP_DIR}/existing-cloud-bin"
  write_p1_offline_cache "${cache}"
  write_p1_install_chain_fakes "${cache}"
  write_existing_cloud_config "${config}"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
exit 0
EOF_PSQL
  chmod +x "${stub_bin}/psql"

  POSTGRES_APP_URL="postgresql://agentsmith:postgres-secret-value@existing-postgres.example.com:5432/agentsmith_lite" \
    JUICEFS_META_URL="postgresql://juicefs:juicefs-secret-value@existing-postgres.example.com:5432/juicefs_meta" \
    S3_ACCESS_KEY="existing-access-key" \
    S3_SECRET_KEY="existing-secret-value" \
    CALL_LOG="${call_log}" \
    K3S_AIRGAP_DIR="${TMP_DIR}/existing-cloud-airgap" \
    PATH="${stub_bin}:${PATH}" \
    "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" >"${out}" 2>&1 || {
      printf '%s\n' "install-offline output:" >&2
      sed -n '1,220p' "${out}" >&2
      fail "existing-cloud p1-real validation did not complete"
    }

  assert_not_contains "${call_log}" "apply -f ${output}/rendered/offline-install/postgres-secret.yaml"
  assert_not_contains "${call_log}" "apply -f ${output}/rendered/offline-install/postgres.yaml"
  assert_not_contains "${call_log}" "rollout status statefulset/postgres"
  assert_not_contains "${call_log}" "exec -i statefulset/postgres"
  assert_not_contains "${call_log}" "minio-secret.yaml"
  assert_not_contains "${call_log}" "minio.yaml"
  assert_not_contains "${call_log}" "statefulset/minio"
  assert_not_contains "${call_log}" "minio-bucket-init"
  [[ ! -e "${output}/rendered/offline-install/minio-secret.yaml" ]] || fail "existing-cloud rendered a self-hosted MinIO Secret"
  [[ ! -e "${output}/rendered/offline-install/minio.yaml" ]] || fail "existing-cloud rendered a self-hosted MinIO StatefulSet"
  [[ ! -e "${output}/rendered/offline-install/minio-bucket-init-job.yaml" ]] || fail "existing-cloud rendered a self-hosted MinIO bucket init Job"
  assert_contains "${out}" "doctor reported partial"
  assert_not_contains "${out}" "postgres-secret-value"
  assert_not_contains "${out}" "juicefs-secret-value"
  assert_not_contains "${out}" "existing-access-key"
  assert_not_contains "${out}" "existing-secret-value"
  assert_not_contains "${call_log}" "postgres-secret-value"
  assert_not_contains "${call_log}" "juicefs-secret-value"
  assert_not_contains "${call_log}" "existing-access-key"
  assert_not_contains "${call_log}" "existing-secret-value"
  pass "existing-cloud p1-real install validates without mutating self-hosted Postgres"
}

test_p1_real_offline_cache_rejects_missing_image_archive_sha() {
  local cache="${TMP_DIR}/offline-cache-p1-missing-sha"
  local config="${TMP_DIR}/substrates-p1-missing-sha.yaml"
  local output="${TMP_DIR}/offline-p1-missing-sha-out"
  local out="${TMP_DIR}/install-offline-p1-missing-sha.out"
  write_p1_offline_cache "${cache}" "missing-image-sha"
  write_config "${config}"
  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a p1-real images.lock archive without sha256"
  fi
  assert_contains "${out}" "images.lock archive entry is missing sha256"
  pass "S5 p1-real offline-cache contract rejects archives without images.lock sha256"
}

test_p1_real_offline_cache_rejects_public_download_references_in_images_lock() {
  local cache="${TMP_DIR}/offline-cache-p1-images-lock-url"
  local config="${TMP_DIR}/substrates-p1-images-lock-url.yaml"
  local output="${TMP_DIR}/offline-p1-images-lock-url-out"
  local out="${TMP_DIR}/install-offline-p1-images-lock-url.out"
  local leaked_url="https://registry-1.docker.io/v2/library/postgres"
  write_p1_offline_cache "${cache}"
  write_config "${config}"
  printf '    sourceUrl: %s\n' "${leaked_url}" >>"${cache}/images/images.lock"
  refresh_checksum_entry "${cache}" "images/images.lock"
  refresh_manifest_artifact_checksum "${cache}" "images/images.lock"
  refresh_manifest_checksum_entry "${cache}"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a public download URL in p1-real images.lock"
  fi
  assert_contains "${out}" "public download references are not allowed"
  assert_contains "${out}" "images/images.lock"
  assert_not_contains "${out}" "${leaked_url}"
  pass "S5 p1-real offline-cache contract rejects public download references in images.lock"
}

test_p1_real_offline_cache_rejects_missing_bootstrap_artifact_entries() {
  local config="${TMP_DIR}/substrates-p1-missing-bootstrap.yaml"
  local spec path kind label cache output out
  write_config "${config}"

  for spec in \
    "scripts/import-images.sh|script|import-script" \
    "manifests/namespace-bootstrap/namespace.yaml|manifest|namespace-bootstrap"
  do
    IFS='|' read -r path kind label <<<"${spec}"
    cache="${TMP_DIR}/offline-cache-p1-missing-${label}"
    output="${TMP_DIR}/offline-p1-missing-${label}-out"
    out="${TMP_DIR}/install-offline-p1-missing-${label}.out"
    write_p1_offline_cache "${cache}"
    remove_manifest_artifact_entry "${cache}/manifest.yaml" "${path}"
    refresh_manifest_checksum_entry "${cache}"

    if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
      fail "install-offline accepted a p1-real cache missing ${path} from manifest artifacts"
    fi
    assert_contains "${out}" "missing required p1-real artifact ${path} with kind ${kind}"
  done

  pass "S5 p1-real offline-cache contract rejects missing namespace bootstrap and import script artifact entries"
}

test_offline_cache_rejects_manifest_artifact_missing_from_checksums() {
  local cache="${TMP_DIR}/offline-cache-missing-artifact-checksum"
  local config="${TMP_DIR}/substrates-missing-artifact-checksum.yaml"
  local output="${TMP_DIR}/offline-missing-artifact-checksum-out"
  local out="${TMP_DIR}/install-offline-missing-artifact-checksum.out"
  write_p1_offline_cache "${cache}"
  write_config "${config}"
  remove_checksum_entry "${cache}" "scripts/import-images.sh"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a cache whose checksums.txt omitted scripts/import-images.sh"
  fi
  assert_contains "${out}" "checksums.txt is missing required entry: scripts/import-images.sh"
  pass "S5 offline-cache contract requires checksums.txt to cover every manifest artifact"
}

test_p1_real_offline_cache_rejects_missing_dependency_oci_manifest_entry() {
  local cache="${TMP_DIR}/offline-cache-p1-missing-oci-manifest"
  local config="${TMP_DIR}/substrates-p1-missing-oci-manifest.yaml"
  local output="${TMP_DIR}/offline-p1-missing-oci-manifest-out"
  local out="${TMP_DIR}/install-offline-p1-missing-oci-manifest.out"
  write_p1_offline_cache "${cache}"
  write_config "${config}"
  remove_manifest_artifact_entry "${cache}/manifest.yaml" "images/oci/minio.tar"
  refresh_manifest_checksum_entry "${cache}"

  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a p1-real cache missing dependency OCI archive from manifest artifacts"
  fi
  assert_contains "${out}" "missing required p1-real artifact images/oci/minio.tar with kind oci-archive"
  pass "S5 p1-real offline-cache contract requires dependency OCI archives in manifest artifacts"
}

test_download_online_generates_p1_real_cache_from_artifact_lock() {
  local fixtures="${TMP_DIR}/download-fixtures"
  local lock_file="${TMP_DIR}/offline-artifacts.env"
  local cache="${TMP_DIR}/downloaded-offline-cache"
  local config="${TMP_DIR}/downloaded-substrates.yaml"
  local output="${TMP_DIR}/downloaded-offline-out"
  local download_out="${TMP_DIR}/download-online-p1.out"
  local install_out="${TMP_DIR}/install-downloaded-p1.out"
  local import_out="${TMP_DIR}/import-downloaded-p1.out"
  local doctor_out="${TMP_DIR}/doctor-downloaded-p1.out"
  local report="${TMP_DIR}/doctor-downloaded-p1.json"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}"
  write_config "${config}"

  "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${download_out}" 2>&1
  assert_contains "${download_out}" "offline cache contract validated (p1-real)"
  assert_contains "${download_out}" "wrote p1-real offline cache"
  assert_contains "${cache}/manifest.yaml" "cacheMode: p1-real"
  assert_contains "${cache}/manifest.yaml" "path: scripts/import-images.sh"
  assert_contains "${cache}/manifest.yaml" "path: manifests/namespace-bootstrap/namespace.yaml"
  assert_contains "${cache}/manifest.yaml" "path: bin/helm"
  assert_contains "${cache}/manifest.yaml" "path: images/oci/juicefs-csi-liveness-probe.tar"
  assert_contains "${cache}/manifest.yaml" "path: images/oci/juicefs-csi-node-driver-registrar.tar"
  assert_contains "${cache}/manifest.yaml" "path: images/oci/juicefs-csi-provisioner.tar"
  assert_contains "${cache}/manifest.yaml" "path: images/oci/juicefs-csi-resizer.tar"
  assert_contains "${cache}/checksums.txt" "scripts/import-images.sh"
  assert_contains "${cache}/checksums.txt" "manifests/namespace-bootstrap/namespace.yaml"
  assert_contains "${cache}/checksums.txt" "bin/helm"
  assert_contains "${cache}/checksums.txt" "images/oci/juicefs-csi-liveness-probe.tar"
  assert_contains "${cache}/images/images.lock" "image: docker.io/library/postgres@sha256:"
  assert_contains "${cache}/images/images.lock" "archive: images/oci/postgres.tar"
  assert_contains "${cache}/images/images.lock" "name: minio-client"
  assert_contains "${cache}/images/images.lock" "image: quay.io/minio/mc@sha256:"
  assert_contains "${cache}/images/images.lock" "archive: images/oci/minio-client.tar"
  assert_contains "${cache}/images/images.lock" "name: juicefs-csi"
  assert_contains "${cache}/images/images.lock" "image: docker.io/juicedata/juicefs-csi-driver:v0.31.10@sha256:"
  assert_contains "${cache}/images/images.lock" "name: juicefs-csi-liveness-probe"
  assert_contains "${cache}/images/images.lock" "archive: images/oci/juicefs-csi-liveness-probe.tar"
  assert_contains "${cache}/images/images.lock" "name: juicefs-csi-node-driver-registrar"
  assert_contains "${cache}/images/images.lock" "archive: images/oci/juicefs-csi-node-driver-registrar.tar"
  assert_contains "${cache}/images/images.lock" "name: juicefs-csi-provisioner"
  assert_contains "${cache}/images/images.lock" "archive: images/oci/juicefs-csi-provisioner.tar"
  assert_contains "${cache}/images/images.lock" "name: juicefs-csi-resizer"
  assert_contains "${cache}/images/images.lock" "archive: images/oci/juicefs-csi-resizer.tar"
  test -x "${cache}/bin/helm" || fail "download-online did not write executable bin/helm"
  test -x "${cache}/scripts/import-images.sh" || fail "download-online did not write executable scripts/import-images.sh"
  test -f "${cache}/manifests/namespace-bootstrap/namespace.yaml" || fail "download-online did not write namespace bootstrap manifest"
  "${cache}/scripts/import-images.sh" --dry-run >"${import_out}" 2>&1
  assert_contains "${import_out}" "images/images.lock"
  assert_contains "${import_out}" "images/oci/postgres.tar"
  assert_contains "${import_out}" "images/oci/minio-client.tar"
  assert_contains "${import_out}" "images/oci/juicefs-csi-resizer.tar"

  "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${install_out}" 2>&1
  assert_contains "${install_out}" "validated p1-real cache contract"

  "${ROOT_DIR}/scripts/doctor.sh" --env "${output}/substrate.env" --secrets "${output}/substrate.secrets.env" --offline-cache "${cache}" --dry-run --report "${report}" >"${doctor_out}" 2>&1
  assert_contains "${report}" '"overallStatus": "passed"'
  assert_contains "${report}" 'p1-real offline cache contract is complete'
  pass "P1 downloader builds a p1-real offline cache from file:// artifact lock and dry-run consumers accept it"
}

test_download_online_import_helper_rejects_archive_path_escape_in_dry_run() {
  local fixtures="${TMP_DIR}/download-fixtures-import-path-escape"
  local lock_file="${TMP_DIR}/offline-artifacts-import-path-escape.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-import-path-escape"
  local download_out="${TMP_DIR}/download-online-import-path-escape.out"
  local import_out="${TMP_DIR}/import-downloaded-path-escape.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}"

  "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${download_out}" 2>&1
  replace_images_lock_archive_and_sha "${cache}" "images/oci/postgres.tar" "../outside.tar" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  if "${cache}/scripts/import-images.sh" --dry-run >"${import_out}" 2>&1; then
    fail "generated import-images.sh dry-run accepted an images.lock archive path escape"
  fi
  assert_contains "${import_out}" "images.lock archive path"
  pass "P1 downloader import-images helper rejects archive path escape during dry-run"
}

test_download_online_rejects_sha_mismatch() {
  local fixtures="${TMP_DIR}/download-fixtures-sha"
  local lock_file="${TMP_DIR}/offline-artifacts-sha.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-sha"
  local out="${TMP_DIR}/download-online-sha.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}" "sha-mismatch"

  if "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${out}" 2>&1; then
    fail "download-online accepted an artifact whose sha256 did not match"
  fi
  assert_contains "${out}" "sha256 mismatch"
  assert_contains "${out}" "K3S_BINARY_URL"
  pass "P1 downloader rejects artifact sha256 mismatches"
}

test_download_online_rejects_mutable_image_ref() {
  local fixtures="${TMP_DIR}/download-fixtures-mutable"
  local lock_file="${TMP_DIR}/offline-artifacts-mutable.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-mutable"
  local out="${TMP_DIR}/download-online-mutable.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}" "mutable-image"

  if "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${out}" 2>&1; then
    fail "download-online accepted a mutable image reference"
  fi
  assert_contains "${out}" "POSTGRES_IMAGE must be digest-pinned"
  assert_not_contains "${out}" "postgres:16"
  pass "P1 downloader rejects mutable image references"
}

test_download_online_rejects_missing_required_key() {
  local fixtures="${TMP_DIR}/download-fixtures-missing"
  local lock_file="${TMP_DIR}/offline-artifacts-missing.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-missing"
  local out="${TMP_DIR}/download-online-missing.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}" "missing-key"

  if "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${out}" 2>&1; then
    fail "download-online accepted an artifact lock with a missing required key"
  fi
  assert_contains "${out}" "artifact lock is missing required key KUBECTL_BINARY_SHA256"
  pass "P1 downloader rejects artifact locks missing required keys"
}

test_download_online_requires_minio_client_artifact_lock() {
  local fixtures="${TMP_DIR}/download-fixtures-missing-minio-client"
  local lock_file="${TMP_DIR}/offline-artifacts-missing-minio-client.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-missing-minio-client"
  local out="${TMP_DIR}/download-online-missing-minio-client.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}" "missing-minio-client-key"

  if "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${out}" 2>&1; then
    fail "download-online accepted an artifact lock missing minio-client coordinates"
  fi
  assert_contains "${out}" "artifact lock is missing required key MINIO_CLIENT_IMAGE"
  pass "P1 downloader requires minio-client artifact lock coordinates"
}

test_download_online_rejects_mutable_minio_client_image_ref() {
  local fixtures="${TMP_DIR}/download-fixtures-mutable-minio-client"
  local lock_file="${TMP_DIR}/offline-artifacts-mutable-minio-client.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-mutable-minio-client"
  local out="${TMP_DIR}/download-online-mutable-minio-client.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}" "mutable-minio-client-image"

  if "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${out}" 2>&1; then
    fail "download-online accepted a mutable minio-client image reference"
  fi
  assert_contains "${out}" "MINIO_CLIENT_IMAGE must be digest-pinned"
  assert_not_contains "${out}" "quay.io/minio/mc:latest"
  pass "P1 downloader requires digest-pinned minio-client image"
}

test_download_online_requires_csi_sidecar_artifact_lock() {
  local fixtures="${TMP_DIR}/download-fixtures-missing-csi-sidecar"
  local lock_file="${TMP_DIR}/offline-artifacts-missing-csi-sidecar.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-missing-csi-sidecar"
  local out="${TMP_DIR}/download-online-missing-csi-sidecar.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}" "missing-csi-sidecar-key"

  if "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${out}" 2>&1; then
    fail "download-online accepted an artifact lock missing CSI sidecar coordinates"
  fi
  assert_contains "${out}" "artifact lock is missing required key JUICEFS_CSI_LIVENESS_PROBE_IMAGE"
  pass "P6.5 downloader requires CSI sidecar artifact lock coordinates"
}

test_download_online_rejects_mutable_csi_sidecar_image_ref() {
  local fixtures="${TMP_DIR}/download-fixtures-mutable-csi-sidecar"
  local lock_file="${TMP_DIR}/offline-artifacts-mutable-csi-sidecar.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-mutable-csi-sidecar"
  local out="${TMP_DIR}/download-online-mutable-csi-sidecar.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}" "mutable-csi-sidecar-image"

  if "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${out}" 2>&1; then
    fail "download-online accepted a mutable CSI sidecar image reference"
  fi
  assert_contains "${out}" "JUICEFS_CSI_LIVENESS_PROBE_IMAGE must be digest-pinned"
  assert_not_contains "${out}" "registry.k8s.io/sig-storage/livenessprobe:latest"
  pass "P6.5 downloader requires digest-pinned CSI sidecar images"
}

test_download_online_rejects_untagged_helm_consumed_image_ref() {
  local fixtures="${TMP_DIR}/download-fixtures-untagged-helm-image"
  local lock_file="${TMP_DIR}/offline-artifacts-untagged-helm-image.env"
  local cache="${TMP_DIR}/downloaded-offline-cache-untagged-helm-image"
  local out="${TMP_DIR}/download-online-untagged-helm-image.out"
  write_downloader_fixtures "${fixtures}"
  write_artifact_lock "${fixtures}" "${lock_file}" "untagged-helm-image"

  if "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock_file}" --output "${cache}" --force >"${out}" 2>&1; then
    fail "download-online accepted a Helm-consumed image reference without a tag"
  fi
  assert_contains "${out}" "JUICEFS_CSI_IMAGE must include a tag before @sha256 for Helm values rendering"
  assert_not_contains "${out}" "docker.io/juicedata/juicefs-csi-driver@sha256:"
  pass "P6.5 downloader rejects Helm-consumed image refs that cannot be split into repository and tag"
}

test_substrate_only_doctor_dry_run_is_factual_and_redacted() {
  local env_dir="${TMP_DIR}/doctor-env"
  local cache="${TMP_DIR}/doctor-cache"
  local report="${TMP_DIR}/doctor-report.json"
  local out="${TMP_DIR}/doctor.out"
  write_valid_env_pair "${env_dir}"
  write_offline_cache "${cache}"
  "${ROOT_DIR}/scripts/doctor.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --offline-cache "${cache}" --dry-run --report "${report}" >"${out}" 2>&1
  assert_contains "${report}" '"dryRun": true'
  assert_contains "${report}" '"overallStatus": "passed"'
  assert_contains "${report}" '"scope": "substrate-only"'
  assert_contains "${report}" '"k8s"'
  assert_contains "${report}" '"postgres-app"'
  assert_contains "${report}" '"postgres-juicefs-meta"'
  assert_contains "${report}" '"s3"'
  assert_contains "${report}" '"juicefs-csi"'
  assert_contains "${report}" '"rwx"'
  assert_contains "${report}" '"status": "passed"'
  assert_contains "${report}" '"offline-cache"'
  assert_contains "${report}" 'raw credentials are substrate/CSI scoped'
  assert_not_contains "${report}" "app-images"
  assert_not_contains "${report}" "botified"
  assert_not_contains "${out}" "minio-secret-value"
  assert_not_contains "${report}" "minio-secret-value"
  pass "S7 substrate-only doctor dry-run proves static contracts, offline-cache, and redaction"
}

test_substrate_only_doctor_live_is_partial_when_live_probes_are_unverified() {
  local env_dir="${TMP_DIR}/doctor-live-env"
  local stub_bin="${TMP_DIR}/doctor-live-bin"
  local report="${TMP_DIR}/doctor-live-report.json"
  local out="${TMP_DIR}/doctor-live.out"
  local psql_log="${TMP_DIR}/doctor-live-psql.log"
  local kubectl_log="${TMP_DIR}/doctor-live-kubectl.log"
  local status
  write_valid_env_pair "${env_dir}"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
: "${KUBECTL_LOG:?KUBECTL_LOG is required}"
printf 'kubectl %s\n' "$*" >>"${KUBECTL_LOG}"
case "$*" in
  *" get pvc agentsmith-lite-files -o jsonpath={.status.phase}"*)
    printf 'Bound'
    ;;
esac
exit 0
EOF_KUBECTL
  cat >"${stub_bin}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
: "${PSQL_LOG:?PSQL_LOG is required}"
printf 'psql %s\n' "$*" >>"${PSQL_LOG}"
case "$*" in
  *agentsmith_lite*) [[ "${PGPASSWORD:-}" == "postgres-secret-value" ]] || exit 18 ;;
  *juicefs_meta*) [[ "${PGPASSWORD:-}" == "juicefs-secret-value" ]] || exit 19 ;;
esac
exit 0
EOF_PSQL
  chmod +x "${stub_bin}/kubectl" "${stub_bin}/psql"

  set +e
  KUBECTL_LOG="${kubectl_log}" PSQL_LOG="${psql_log}" PATH="${stub_bin}:${PATH}" "${ROOT_DIR}/scripts/doctor.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --report "${report}" >"${out}" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 2 ]] || fail "doctor live mode should exit 2 for partial checks, got ${status}"
  assert_contains "${report}" '"dryRun": false'
  assert_contains "${report}" '"overallStatus": "partial"'
  assert_contains "${report}" '"postgres-app"'
  assert_contains "${report}" '"postgres-juicefs-meta"'
  assert_contains "${report}" "app database accepted a simple query"
  assert_contains "${report}" "JuiceFS metadata database accepted a simple query"
  assert_contains "${report}" "live JuiceFS PVC phase is Bound"
  assert_contains "${report}" '"status": "partial"'
  assert_contains "${report}" "live S3 read/write/delete probe is not implemented"
  assert_contains "${report}" "RWX was not verified"
  assert_contains "${kubectl_log}" "get storageclass agentsmith-lite-juicefs-rwx"
  assert_contains "${kubectl_log}" "-n agentsmith get secret agentsmith-lite-juicefs"
  assert_contains "${kubectl_log}" "-n agentsmith get pvc agentsmith-lite-files"
  assert_contains "${kubectl_log}" "-n agentsmith get pvc agentsmith-lite-files -o jsonpath={.status.phase}"
  assert_not_contains "${kubectl_log}" " apply "
  assert_not_contains "${kubectl_log}" " delete "
  assert_not_contains "${kubectl_log}" " create "
  assert_not_contains "${out}" "minio-secret-value"
  assert_not_contains "${report}" "minio-secret-value"
  assert_not_contains "${kubectl_log}" "juicefs-secret-value"
  assert_not_contains "${kubectl_log}" "minio-secret-value"
  assert_not_contains "${kubectl_log}" "postgresql://"
  assert_contains "${psql_log}" "-h postgres.agentsmith.svc.cluster.local -p 5432 -U agentsmith -d agentsmith_lite"
  assert_contains "${psql_log}" "-h postgres.agentsmith.svc.cluster.local -p 5432 -U juicefs -d juicefs_meta"
  assert_not_contains "${psql_log}" "postgres-secret-value"
  assert_not_contains "${psql_log}" "juicefs-secret-value"
  assert_not_contains "${psql_log}" "postgresql://"
  assert_not_contains "${psql_log}" "postgres://"
  assert_not_contains "${out}" "postgresql://"
  assert_not_contains "${report}" "postgresql://"
  pass "S7 doctor live mode is not falsely green when S3/RWX live checks are unverified"
}

test_substrate_only_doctor_live_fails_when_pvc_phase_is_pending() {
  local env_dir="${TMP_DIR}/doctor-live-pvc-pending-env"
  local stub_bin="${TMP_DIR}/doctor-live-pvc-pending-bin"
  local report="${TMP_DIR}/doctor-live-pvc-pending-report.json"
  local out="${TMP_DIR}/doctor-live-pvc-pending.out"
  local kubectl_log="${TMP_DIR}/doctor-live-pvc-pending-kubectl.log"
  local status
  write_valid_env_pair "${env_dir}"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
: "${KUBECTL_LOG:?KUBECTL_LOG is required}"
printf 'kubectl %s\n' "$*" >>"${KUBECTL_LOG}"
case "$*" in
  *" get pvc agentsmith-lite-files -o jsonpath={.status.phase}"*)
    printf 'Pending'
    ;;
esac
exit 0
EOF_KUBECTL
  cat >"${stub_bin}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
exit 0
EOF_PSQL
  chmod +x "${stub_bin}/kubectl" "${stub_bin}/psql"

  set +e
  KUBECTL_LOG="${kubectl_log}" PATH="${stub_bin}:${PATH}" "${ROOT_DIR}/scripts/doctor.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --report "${report}" >"${out}" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 1 ]] || fail "doctor live mode should exit 1 when JuiceFS PVC is Pending, got ${status}"
  assert_contains "${report}" '"overallStatus": "failed"'
  assert_contains "${report}" '"juicefs-csi"'
  assert_contains "${report}" "live JuiceFS PVC phase is Pending, expected Bound"
  assert_contains "${report}" '"rwx"'
  assert_contains "${report}" "RWX was not verified"
  assert_contains "${kubectl_log}" "-n agentsmith get pvc agentsmith-lite-files -o jsonpath={.status.phase}"
  assert_not_contains "${kubectl_log}" " apply "
  assert_not_contains "${kubectl_log}" " delete "
  assert_not_contains "${kubectl_log}" " create "
  assert_not_contains "${out}" "juicefs-secret-value"
  assert_not_contains "${out}" "minio-secret-value"
  assert_not_contains "${report}" "juicefs-secret-value"
  assert_not_contains "${report}" "minio-secret-value"
  assert_not_contains "${kubectl_log}" "postgresql://"
  pass "S7 doctor live mode fails JuiceFS CSI when PVC phase is Pending"
}

test_substrate_only_doctor_live_fails_when_pvc_phase_read_fails() {
  local env_dir="${TMP_DIR}/doctor-live-pvc-read-fail-env"
  local stub_bin="${TMP_DIR}/doctor-live-pvc-read-fail-bin"
  local report="${TMP_DIR}/doctor-live-pvc-read-fail-report.json"
  local out="${TMP_DIR}/doctor-live-pvc-read-fail.out"
  local kubectl_log="${TMP_DIR}/doctor-live-pvc-read-fail-kubectl.log"
  local status
  write_valid_env_pair "${env_dir}"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
: "${KUBECTL_LOG:?KUBECTL_LOG is required}"
printf 'kubectl %s\n' "$*" >>"${KUBECTL_LOG}"
case "$*" in
  *" get pvc agentsmith-lite-files -o jsonpath={.status.phase}"*)
    exit 23
    ;;
esac
exit 0
EOF_KUBECTL
  cat >"${stub_bin}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
exit 0
EOF_PSQL
  chmod +x "${stub_bin}/kubectl" "${stub_bin}/psql"

  set +e
  KUBECTL_LOG="${kubectl_log}" PATH="${stub_bin}:${PATH}" "${ROOT_DIR}/scripts/doctor.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --report "${report}" >"${out}" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 1 ]] || fail "doctor live mode should exit 1 when JuiceFS PVC phase cannot be read, got ${status}"
  assert_contains "${report}" '"overallStatus": "failed"'
  assert_contains "${report}" "live JuiceFS PVC phase could not be read"
  assert_contains "${kubectl_log}" "get storageclass agentsmith-lite-juicefs-rwx"
  assert_contains "${kubectl_log}" "-n agentsmith get secret agentsmith-lite-juicefs"
  assert_contains "${kubectl_log}" "-n agentsmith get pvc agentsmith-lite-files"
  assert_contains "${kubectl_log}" "-n agentsmith get pvc agentsmith-lite-files -o jsonpath={.status.phase}"
  assert_not_contains "${kubectl_log}" " apply "
  assert_not_contains "${kubectl_log}" " delete "
  assert_not_contains "${kubectl_log}" " create "
  assert_not_contains "${out}" "juicefs-secret-value"
  assert_not_contains "${report}" "juicefs-secret-value"
  assert_not_contains "${kubectl_log}" "postgresql://"
  pass "S7 doctor live mode fails JuiceFS CSI when PVC phase cannot be read"
}

test_substrate_only_doctor_live_fails_when_pvc_is_missing() {
  local env_dir="${TMP_DIR}/doctor-live-pvc-missing-env"
  local stub_bin="${TMP_DIR}/doctor-live-pvc-missing-bin"
  local report="${TMP_DIR}/doctor-live-pvc-missing-report.json"
  local out="${TMP_DIR}/doctor-live-pvc-missing.out"
  local kubectl_log="${TMP_DIR}/doctor-live-pvc-missing-kubectl.log"
  local status
  write_valid_env_pair "${env_dir}"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
: "${KUBECTL_LOG:?KUBECTL_LOG is required}"
printf 'kubectl %s\n' "$*" >>"${KUBECTL_LOG}"
case "$*" in
  *"-n agentsmith get pvc agentsmith-lite-files"*)
    exit 24
    ;;
esac
exit 0
EOF_KUBECTL
  cat >"${stub_bin}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
exit 0
EOF_PSQL
  chmod +x "${stub_bin}/kubectl" "${stub_bin}/psql"

  set +e
  KUBECTL_LOG="${kubectl_log}" PATH="${stub_bin}:${PATH}" "${ROOT_DIR}/scripts/doctor.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --report "${report}" >"${out}" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 1 ]] || fail "doctor live mode should exit 1 when JuiceFS PVC is missing, got ${status}"
  assert_contains "${report}" '"overallStatus": "failed"'
  assert_contains "${report}" "live JuiceFS StorageClass, Secret, or PVC is missing"
  assert_contains "${report}" "RWX was not verified"
  assert_contains "${kubectl_log}" "get storageclass agentsmith-lite-juicefs-rwx"
  assert_contains "${kubectl_log}" "-n agentsmith get secret agentsmith-lite-juicefs"
  assert_contains "${kubectl_log}" "-n agentsmith get pvc agentsmith-lite-files"
  assert_not_contains "${kubectl_log}" "jsonpath={.status.phase}"
  assert_not_contains "${kubectl_log}" " apply "
  assert_not_contains "${kubectl_log}" " delete "
  assert_not_contains "${kubectl_log}" " create "
  assert_not_contains "${out}" "juicefs-secret-value"
  assert_not_contains "${report}" "juicefs-secret-value"
  assert_not_contains "${kubectl_log}" "postgresql://"
  pass "S7 doctor live mode fails JuiceFS CSI when PVC is missing"
}

test_substrate_only_doctor_live_fails_when_juicefs_meta_db_query_fails() {
  local env_dir="${TMP_DIR}/doctor-live-meta-fail-env"
  local stub_bin="${TMP_DIR}/doctor-live-meta-fail-bin"
  local report="${TMP_DIR}/doctor-live-meta-fail-report.json"
  local out="${TMP_DIR}/doctor-live-meta-fail.out"
  local psql_log="${TMP_DIR}/doctor-live-meta-fail-psql.log"
  local status
  write_valid_env_pair "${env_dir}"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
exit 0
EOF_KUBECTL
  cat >"${stub_bin}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
set -euo pipefail
: "${PSQL_LOG:?PSQL_LOG is required}"
printf 'psql %s\n' "$*" >>"${PSQL_LOG}"
case "$*" in
  *"juicefs_meta"*) exit 17 ;;
esac
exit 0
EOF_PSQL
  chmod +x "${stub_bin}/kubectl" "${stub_bin}/psql"

  set +e
  PSQL_LOG="${psql_log}" PATH="${stub_bin}:${PATH}" "${ROOT_DIR}/scripts/doctor.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --report "${report}" >"${out}" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 1 ]] || fail "doctor live mode should exit 1 when JuiceFS metadata query fails, got ${status}"
  assert_contains "${report}" '"overallStatus": "failed"'
  assert_contains "${report}" '"postgres-app"'
  assert_contains "${report}" "app database accepted a simple query"
  assert_contains "${report}" '"postgres-juicefs-meta"'
  assert_contains "${report}" "JuiceFS metadata database did not accept a simple query"
  assert_not_contains "${out}" "postgres-secret-value"
  assert_not_contains "${out}" "juicefs-secret-value"
  assert_not_contains "${report}" "postgres-secret-value"
  assert_not_contains "${report}" "juicefs-secret-value"
  assert_not_contains "${psql_log}" "postgres-secret-value"
  assert_not_contains "${psql_log}" "juicefs-secret-value"
  assert_not_contains "${psql_log}" "postgresql://"
  assert_not_contains "${psql_log}" "postgres://"
  pass "S7 doctor live mode fails when JuiceFS metadata database query fails"
}

test_juicefs_csi_contract() {
  local env_dir="${TMP_DIR}/juicefs-env"
  local out="${TMP_DIR}/juicefs.out"
  write_valid_env_pair "${env_dir}"
  "${ROOT_DIR}/scripts/validate-juicefs-contract.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --manifests "${ROOT_DIR}/manifests/juicefs-csi" >"${out}" 2>&1
  assert_contains "${out}" "JuiceFS CSI contract validated"
  assert_contains "${out}" "not app workload env"
  assert_not_contains "${out}" "juicefs-secret-value"
  pass "S3 JuiceFS CSI contract validates secret shape, RWX, and redaction boundary"
}

test_juicefs_csi_contract_renders_custom_env_names() {
  local env_dir="${TMP_DIR}/juicefs-custom-env"
  local out="${TMP_DIR}/juicefs-custom.out"
  write_valid_env_pair "${env_dir}"
  replace_env_value "${env_dir}/substrate.env" "KUBE_NAMESPACE" "custom-ns"
  replace_env_value "${env_dir}/substrate.env" "S3_BUCKET" "custom-bucket"
  replace_env_value "${env_dir}/substrate.env" "JUICEFS_VOLUME_NAME" "custom-volume"
  replace_env_value "${env_dir}/substrate.env" "JUICEFS_BUCKET" "s3://custom-bucket/custom-prefix/"
  replace_env_value "${env_dir}/substrate.env" "JUICEFS_SECRET_NAME" "custom-juicefs-secret"
  replace_env_value "${env_dir}/substrate.env" "JUICEFS_STORAGE_CLASS" "custom-juicefs-rwx"
  replace_env_value "${env_dir}/substrate.env" "JUICEFS_PVC_NAME" "custom-files-pvc"
  "${ROOT_DIR}/scripts/validate-juicefs-contract.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --manifests "${ROOT_DIR}/manifests/juicefs-csi" >"${out}" 2>&1
  assert_contains "${out}" "storageClass=custom-juicefs-rwx"
  assert_contains "${out}" "pvc=custom-files-pvc"
  assert_not_contains "${out}" "juicefs-secret-value"
  pass "S6 JuiceFS CSI contract renders custom namespace, secretName, storageClass, PVC, RWX, and bucket URL"
}

test_forbidden_copy_guard() {
  local out="${TMP_DIR}/forbidden-copy.out"
  "${ROOT_DIR}/scripts/check-forbidden-copy.sh" >"${out}" 2>&1
  assert_contains "${out}" "forbidden-copy guard passed"
  pass "S4 forbidden-copy guard rejects old governance/reference surfaces"
}

test_validate_env_split_and_redaction
test_validate_env_rejects_secret_leak
test_validate_env_rejects_loose_secret_mode
test_offline_install_validates_cache_without_network
test_offline_cache_rejects_public_download_contract
test_offline_cache_rejects_public_download_references_in_checksums
test_offline_cache_rejects_manifest_artifact_path_escape_without_reading_outside
test_offline_cache_rejects_checksums_path_escape
test_p1_real_offline_cache_rejects_images_lock_archive_path_escape
test_offline_cache_scans_urls_before_cache_mode_errors_without_leaking
test_offline_cache_rejects_url_suffix_fields_with_file_urls
test_p1_real_offline_cache_requires_artifacts_and_archive_sha
test_p1_real_offline_cache_requires_cached_helm
test_p1_real_offline_cache_requires_csi_sidecar_archives_and_lock_entries
test_p1_real_offline_cache_requires_minio_client_oci_archive
test_p1_real_offline_cache_requires_minio_client_images_lock_archive_sha
test_p1_real_offline_cache_rejects_mutable_minio_client_image_ref
test_p0_contract_offline_install_non_dry_run_still_fails
test_p1_real_offline_install_dry_run_skips_cluster_mutation
test_p1_real_offline_install_non_dry_run_runs_cached_chain
test_p1_real_offline_install_rejects_invalid_cache_before_mutation
test_juicefs_format_job_renders_digest_pinned_image_and_secret_refs
test_p1_real_offline_install_fails_on_juicefs_format_mismatch_before_pvc
test_minio_bucket_init_job_keeps_credentials_out_of_mc_argv
test_p1_real_offline_install_rejects_mismatched_postgres_urls_before_mutation
test_p1_real_offline_install_rejects_invalid_postgres_url_before_mutation
test_existing_cloud_offline_install_does_not_mutate_self_hosted_postgres
test_p1_real_offline_cache_rejects_missing_image_archive_sha
test_p1_real_offline_cache_rejects_public_download_references_in_images_lock
test_p1_real_offline_cache_rejects_missing_bootstrap_artifact_entries
test_offline_cache_rejects_manifest_artifact_missing_from_checksums
test_p1_real_offline_cache_rejects_missing_dependency_oci_manifest_entry
test_download_online_generates_p1_real_cache_from_artifact_lock
test_download_online_import_helper_rejects_archive_path_escape_in_dry_run
test_download_online_rejects_sha_mismatch
test_download_online_rejects_mutable_image_ref
test_download_online_rejects_missing_required_key
test_download_online_requires_minio_client_artifact_lock
test_download_online_rejects_mutable_minio_client_image_ref
test_download_online_requires_csi_sidecar_artifact_lock
test_download_online_rejects_mutable_csi_sidecar_image_ref
test_download_online_rejects_untagged_helm_consumed_image_ref
test_substrate_only_doctor_dry_run_is_factual_and_redacted
test_substrate_only_doctor_live_is_partial_when_live_probes_are_unverified
test_substrate_only_doctor_live_fails_when_pvc_phase_is_pending
test_substrate_only_doctor_live_fails_when_pvc_phase_read_fails
test_substrate_only_doctor_live_fails_when_pvc_is_missing
test_substrate_only_doctor_live_fails_when_juicefs_meta_db_query_fails
test_juicefs_csi_contract
test_juicefs_csi_contract_renders_custom_env_names
test_forbidden_copy_guard

printf '1..%d\n' "${pass_count}"
