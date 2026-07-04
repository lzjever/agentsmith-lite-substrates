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
  printf '#!/usr/bin/env sh\nexit 0\n' >"${dir}/scripts/install-k3s.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "import-images dry-run\\n"\n' >"${dir}/scripts/import-images.sh"
  chmod +x "${dir}/bin/k3s" "${dir}/bin/kubectl" "${dir}/scripts/install-k3s.sh" "${dir}/scripts/import-images.sh"
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: agentsmith\n' >"${dir}/manifests/namespace-bootstrap/namespace.yaml"
  printf 'k3s airgap archive fixture\n' >"${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst"
  printf 'juicefs csi chart fixture\n' >"${dir}/charts/juicefs-csi.tgz"
  printf 'postgres oci archive fixture\n' >"${dir}/images/oci/postgres.tar"
  printf 'minio oci archive fixture\n' >"${dir}/images/oci/minio.tar"
  printf 'juicefs csi oci archive fixture\n' >"${dir}/images/oci/juicefs-csi.tar"

  local k3s_sum kubectl_sum install_sum import_sum namespace_sum airgap_sum csi_chart_sum postgres_sum minio_sum juicefs_sum lock_sum manifest_sum
  k3s_sum="$(sha256_file "${dir}/bin/k3s")"
  kubectl_sum="$(sha256_file "${dir}/bin/kubectl")"
  install_sum="$(sha256_file "${dir}/scripts/install-k3s.sh")"
  import_sum="$(sha256_file "${dir}/scripts/import-images.sh")"
  namespace_sum="$(sha256_file "${dir}/manifests/namespace-bootstrap/namespace.yaml")"
  airgap_sum="$(sha256_file "${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst")"
  csi_chart_sum="$(sha256_file "${dir}/charts/juicefs-csi.tgz")"
  postgres_sum="$(sha256_file "${dir}/images/oci/postgres.tar")"
  minio_sum="$(sha256_file "${dir}/images/oci/minio.tar")"
  juicefs_sum="$(sha256_file "${dir}/images/oci/juicefs-csi.tar")"

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
  - name: juicefs-csi
    image: docker.io/juicedata/juicefs-csi-driver@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    archive: images/oci/juicefs-csi.tar
    sha256: ${juicefs_sum}
EOF_LOCK
  else
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
    sha256: ${minio_sum}
  - name: juicefs-csi
    image: docker.io/juicedata/juicefs-csi-driver@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    archive: images/oci/juicefs-csi.tar
    sha256: ${juicefs_sum}
EOF_LOCK
  fi
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
  - path: images/oci/juicefs-csi.tar
    sha256: ${juicefs_sum}
    kind: oci-archive
EOF_MANIFEST
  manifest_sum="$(sha256_file "${dir}/manifest.yaml")"
  cat >"${dir}/checksums.txt" <<EOF_SUMS
${manifest_sum}  manifest.yaml
${k3s_sum}  bin/k3s
${install_sum}  scripts/install-k3s.sh
${airgap_sum}  images/k3s/k3s-airgap-images-amd64.tar.zst
${kubectl_sum}  bin/kubectl
${import_sum}  scripts/import-images.sh
${namespace_sum}  manifests/namespace-bootstrap/namespace.yaml
${lock_sum}  images/images.lock
${csi_chart_sum}  charts/juicefs-csi.tgz
${postgres_sum}  images/oci/postgres.tar
${minio_sum}  images/oci/minio.tar
${juicefs_sum}  images/oci/juicefs-csi.tar
EOF_SUMS
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
  *postgresql://*|*postgres://*|*postgres-secret-value*|*juicefs-secret-value*) exit 54 ;;
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
exit 0
EOF_KUBECTL

  chmod +x "${cache}/scripts/install-k3s.sh" "${cache}/scripts/import-images.sh" "${cache}/bin/kubectl"
  refresh_cache_artifacts "${cache}" "scripts/install-k3s.sh" "scripts/import-images.sh" "bin/kubectl"
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
  printf 'juicefs csi chart fixture from downloader\n' >"${dir}/juicefs-csi.tgz"
  printf 'postgres oci archive fixture from downloader\n' >"${dir}/postgres.tar"
  printf 'minio oci archive fixture from downloader\n' >"${dir}/minio.tar"
  printf 'juicefs csi oci archive fixture from downloader\n' >"${dir}/juicefs-csi.tar"
}

write_artifact_lock() {
  local fixtures="$1"
  local lock_file="$2"
  local variant="${3:-valid}"
  local k3s_sha install_sha airgap_sha kubectl_sha csi_chart_sha postgres_sha minio_sha juicefs_sha
  k3s_sha="$(sha256_file "${fixtures}/k3s")"
  install_sha="$(sha256_file "${fixtures}/install-k3s.sh")"
  airgap_sha="$(sha256_file "${fixtures}/k3s-airgap-images-amd64.tar.zst")"
  kubectl_sha="$(sha256_file "${fixtures}/kubectl")"
  csi_chart_sha="$(sha256_file "${fixtures}/juicefs-csi.tgz")"
  postgres_sha="$(sha256_file "${fixtures}/postgres.tar")"
  minio_sha="$(sha256_file "${fixtures}/minio.tar")"
  juicefs_sha="$(sha256_file "${fixtures}/juicefs-csi.tar")"

  local postgres_image="docker.io/library/postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  if [[ "${variant}" == "mutable-image" ]]; then
    postgres_image="docker.io/library/postgres:16"
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
JUICEFS_CSI_ARTIFACT_URL=$(file_url "${fixtures}/juicefs-csi.tgz")
JUICEFS_CSI_ARTIFACT_SHA256=${csi_chart_sha}
POSTGRES_IMAGE=${postgres_image}
POSTGRES_ARCHIVE_URL=$(file_url "${fixtures}/postgres.tar")
POSTGRES_ARCHIVE_SHA256=${postgres_sha}
MINIO_IMAGE=quay.io/minio/minio@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MINIO_ARCHIVE_URL=$(file_url "${fixtures}/minio.tar")
MINIO_ARCHIVE_SHA256=${minio_sha}
JUICEFS_CSI_IMAGE=docker.io/juicedata/juicefs-csi-driver@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
JUICEFS_CSI_ARCHIVE_URL=$(file_url "${fixtures}/juicefs-csi.tar")
JUICEFS_CSI_ARCHIVE_SHA256=${juicefs_sha}
EOF_LOCK

  if [[ "${variant}" == "missing-key" ]]; then
    local tmp="${lock_file}.tmp"
    grep -v '^KUBECTL_BINARY_SHA256=' "${lock_file}" >"${tmp}"
    mv "${tmp}" "${lock_file}"
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
  assert_contains "${rendered}/postgres-secret.yaml" "name: agentsmith-lite-postgres"
  assert_contains "${rendered}/postgres-secret.yaml" "username:"
  assert_contains "${rendered}/postgres-secret.yaml" "password:"
  assert_contains "${rendered}/postgres-secret.yaml" "database:"
  assert_contains "${rendered}/postgres-secret.yaml" "juicefsUsername:"
  assert_contains "${rendered}/postgres-secret.yaml" "juicefsPassword:"
  assert_contains "${rendered}/postgres-secret.yaml" "juicefsDatabase:"

  assert_line_order "${call_log}" \
    "install-k3s" \
    "import-images args=" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${cache}/manifests/namespace-bootstrap/namespace.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/juicefs-secret.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/juicefs-storageclass-pvc.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/postgres-secret.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/postgres.yaml" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith rollout status statefulset/postgres --timeout=180s" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite -n agentsmith exec -i statefulset/postgres -- sh -c psql -v ON_ERROR_STOP=1 -U \"\${POSTGRES_USER}\" -d postgres" \
    "kubectl exec stdin bytes=" \
    "POSTGRES_PASSWORD postgres.agentsmith.svc.cluster.local 5432 agentsmith agentsmith_lite" \
    "JUICEFS_META_PASSWORD postgres.agentsmith.svc.cluster.local 5432 juicefs juicefs_meta" \
    "kubectl --kubeconfig ${output}/kubeconfig --context agentsmith-lite apply -f ${rendered}/minio.yaml"
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
  assert_not_contains "${call_log}" "postgres-secret-value"
  assert_not_contains "${call_log}" "juicefs-secret-value"
  assert_not_contains "${call_log}" "postgresql://"
  assert_not_contains "${call_log}" "postgres://"
  assert_not_contains "${report}" "postgres-secret-value"
  assert_not_contains "${report}" "juicefs-secret-value"
  pass "P1 offline installer non-dry-run executes cached k3s/import/kubectl chain without public network tools"
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
  assert_contains "${out}" "doctor reported partial"
  assert_not_contains "${out}" "postgres-secret-value"
  assert_not_contains "${out}" "juicefs-secret-value"
  assert_not_contains "${call_log}" "postgres-secret-value"
  assert_not_contains "${call_log}" "juicefs-secret-value"
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
  assert_contains "${cache}/checksums.txt" "scripts/import-images.sh"
  assert_contains "${cache}/checksums.txt" "manifests/namespace-bootstrap/namespace.yaml"
  assert_contains "${cache}/images/images.lock" "image: docker.io/library/postgres@sha256:"
  assert_contains "${cache}/images/images.lock" "archive: images/oci/postgres.tar"
  test -x "${cache}/scripts/import-images.sh" || fail "download-online did not write executable scripts/import-images.sh"
  test -f "${cache}/manifests/namespace-bootstrap/namespace.yaml" || fail "download-online did not write namespace bootstrap manifest"
  "${cache}/scripts/import-images.sh" --dry-run >"${import_out}" 2>&1
  assert_contains "${import_out}" "images/images.lock"
  assert_contains "${import_out}" "images/oci/postgres.tar"

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
  local status
  write_valid_env_pair "${env_dir}"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
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
  PSQL_LOG="${psql_log}" PATH="${stub_bin}:${PATH}" "${ROOT_DIR}/scripts/doctor.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --report "${report}" >"${out}" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 2 ]] || fail "doctor live mode should exit 2 for partial checks, got ${status}"
  assert_contains "${report}" '"dryRun": false'
  assert_contains "${report}" '"overallStatus": "partial"'
  assert_contains "${report}" '"postgres-app"'
  assert_contains "${report}" '"postgres-juicefs-meta"'
  assert_contains "${report}" "app database accepted a simple query"
  assert_contains "${report}" "JuiceFS metadata database accepted a simple query"
  assert_contains "${report}" '"status": "partial"'
  assert_contains "${report}" "live S3 read/write/delete probe is not implemented"
  assert_contains "${report}" "RWX was not verified"
  assert_not_contains "${out}" "minio-secret-value"
  assert_not_contains "${report}" "minio-secret-value"
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
test_p0_contract_offline_install_non_dry_run_still_fails
test_p1_real_offline_install_dry_run_skips_cluster_mutation
test_p1_real_offline_install_non_dry_run_runs_cached_chain
test_p1_real_offline_install_rejects_invalid_cache_before_mutation
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
test_substrate_only_doctor_dry_run_is_factual_and_redacted
test_substrate_only_doctor_live_is_partial_when_live_probes_are_unverified
test_substrate_only_doctor_live_fails_when_juicefs_meta_db_query_fails
test_juicefs_csi_contract
test_juicefs_csi_contract_renders_custom_env_names
test_forbidden_copy_guard

printf '1..%d\n' "${pass_count}"
