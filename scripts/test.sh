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
  if ! grep -Fq "${needle}" "${file}"; then
    fail "expected ${file} to contain: ${needle}"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq "${needle}" "${file}"; then
    fail "expected ${file} to redact: ${needle}"
  fi
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
  mkdir -p "${dir}/bin" "${dir}/charts" "${dir}/images/k3s" "${dir}/images/oci" "${dir}/scripts"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${dir}/bin/k3s"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${dir}/bin/kubectl"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${dir}/scripts/install-k3s.sh"
  chmod +x "${dir}/bin/k3s" "${dir}/bin/kubectl" "${dir}/scripts/install-k3s.sh"
  printf 'k3s airgap archive fixture\n' >"${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst"
  printf 'juicefs csi chart fixture\n' >"${dir}/charts/juicefs-csi.tgz"
  printf 'postgres oci archive fixture\n' >"${dir}/images/oci/postgres.tar"
  printf 'minio oci archive fixture\n' >"${dir}/images/oci/minio.tar"
  printf 'juicefs csi oci archive fixture\n' >"${dir}/images/oci/juicefs-csi.tar"

  local k3s_sum kubectl_sum install_sum airgap_sum csi_chart_sum postgres_sum minio_sum juicefs_sum lock_sum manifest_sum
  k3s_sum="$(sha256_file "${dir}/bin/k3s")"
  kubectl_sum="$(sha256_file "${dir}/bin/kubectl")"
  install_sum="$(sha256_file "${dir}/scripts/install-k3s.sh")"
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
${lock_sum}  images/images.lock
${csi_chart_sum}  charts/juicefs-csi.tgz
${postgres_sum}  images/oci/postgres.tar
${minio_sum}  images/oci/minio.tar
${juicefs_sum}  images/oci/juicefs-csi.tar
EOF_SUMS
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
  write_offline_cache "${cache}"
  write_config "${config}"
  printf '\npublicDownloadUrl: https://registry-1.docker.io/v2/\n' >>"${cache}/manifest.yaml"
  if "${ROOT_DIR}/scripts/install-offline.sh" --cache "${cache}" --config "${config}" --output "${output}" --dry-run >"${out}" 2>&1; then
    fail "install-offline accepted a public download URL in offline cache manifest"
  fi
  assert_contains "${out}" "public download references are not allowed"
  pass "S2 offline-cache contract rejects public download references"
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
  assert_contains "${report}" '"postgres"'
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
  local status
  write_valid_env_pair "${env_dir}"
  mkdir -p "${stub_bin}"
  cat >"${stub_bin}/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
exit 0
EOF_KUBECTL
  cat >"${stub_bin}/psql" <<'EOF_PSQL'
#!/usr/bin/env bash
exit 0
EOF_PSQL
  chmod +x "${stub_bin}/kubectl" "${stub_bin}/psql"

  set +e
  PATH="${stub_bin}:${PATH}" "${ROOT_DIR}/scripts/doctor.sh" --env "${env_dir}/substrate.env" --secrets "${env_dir}/substrate.secrets.env" --report "${report}" >"${out}" 2>&1
  status=$?
  set -e
  [[ "${status}" -eq 2 ]] || fail "doctor live mode should exit 2 for partial checks, got ${status}"
  assert_contains "${report}" '"dryRun": false'
  assert_contains "${report}" '"overallStatus": "partial"'
  assert_contains "${report}" '"status": "partial"'
  assert_contains "${report}" "live S3 read/write/delete probe is not implemented"
  assert_contains "${report}" "RWX was not verified"
  assert_not_contains "${out}" "minio-secret-value"
  assert_not_contains "${report}" "minio-secret-value"
  pass "S7 doctor live mode is not falsely green when S3/RWX live checks are unverified"
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
test_p1_real_offline_cache_requires_artifacts_and_archive_sha
test_p1_real_offline_cache_rejects_missing_image_archive_sha
test_substrate_only_doctor_dry_run_is_factual_and_redacted
test_substrate_only_doctor_live_is_partial_when_live_probes_are_unverified
test_juicefs_csi_contract
test_juicefs_csi_contract_renders_custom_env_names
test_forbidden_copy_guard

printf '1..%d\n' "${pass_count}"
