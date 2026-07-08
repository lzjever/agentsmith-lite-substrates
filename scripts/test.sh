#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=lib/s3_probe.sh
source "${ROOT_DIR}/scripts/lib/s3_probe.sh"

POSTGRES_PROBE_IMAGE="docker.io/library/postgres:16@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
S3_PROBE_IMAGE="quay.io/minio/mc:RELEASE.2024-01-01T00-00-00Z@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
RWX_CHECK_IMAGE="docker.io/library/busybox:1.36.1@sha256:3333333333333333333333333333333333333333333333333333333333333333"
FAKE_DIGEST="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

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
    fail "expected ${file} not to contain: ${needle}"
  fi
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp="${file}.tmp"
  local mode=""
  mode="$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}" 2>/dev/null || true)"
  awk -v wanted="${key}" -v replacement="${key}=${value}" '
    BEGIN { found=0 }
    {
      line=$0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      idx=index(line, "=")
      current=idx ? substr(line, 1, idx - 1) : ""
      if (current == wanted) {
        print replacement
        found=1
        next
      }
      print
    }
    END { if (!found) exit 1 }
  ' "${file}" >"${tmp}" || fail "expected ${file} to contain ${key}"
  mv "${tmp}" "${file}"
  [[ -z "${mode}" ]] || chmod "${mode}" "${file}"
}

env_file_value() {
  local file="$1"
  local key="$2"
  local value
  value="$(awk -v wanted="${key}" '
    /^[[:space:]]*($|#)/ { next }
    {
      line=$0
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      idx=index(line, "=")
      current=idx ? substr(line, 1, idx - 1) : ""
      if (current == wanted) {
        print substr(line, idx + 1)
        found=1
      }
    }
    END { if (!found) exit 1 }
  ' "${file}")" || fail "expected ${file} to contain ${key}"
  printf '%s' "${value}"
}

env_file_value_b64() {
  local file="$1"
  local key="$2"
  env_file_value "${file}" "${key}" | base64 | tr -d '\n'
}

assert_command_fails_contains() {
  local out="$1"
  local needle="$2"
  shift 2
  local status=0
  set +e
  "$@" >"${out}" 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail "expected command to fail: $*"
  assert_contains "${out}" "${needle}"
}

fake_file_sha() {
  local file="$1"
  sha256sum "${file}" | awk '{print $1}'
}

write_fake_artifact() {
  local file="$1"
  local content="$2"
  mkdir -p "$(dirname "${file}")"
  printf '%s\n' "${content}" >"${file}"
}

write_fake_p1_artifact_lock() {
  local dir="$1"
  local lock="$2"
  mkdir -p "${dir}/bin" "${dir}/scripts" "${dir}/images/k3s" "${dir}/images/oci" "${dir}/charts"
  cat >"${dir}/bin/k3s" <<'EOF_K3S'
#!/usr/bin/env bash
set -euo pipefail
printf 'unexpected k3s call: %s\n' "$*" >&2
exit 23
EOF_K3S
  cat >"${dir}/scripts/install-k3s.sh" <<'EOF_INSTALL_K3S'
#!/usr/bin/env bash
set -euo pipefail
printf 'unexpected k3s installer call\n' >&2
exit 24
EOF_INSTALL_K3S
  write_fake_artifact "${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst" "fake airgap"
  write_live_kubectl_stub "${dir}/bin/kubectl"
  write_live_helm_stub "${dir}/bin/helm"
  write_fake_artifact "${dir}/charts/juicefs-csi.tgz" "fake juicefs chart"
  chmod +x "${dir}/bin/k3s" "${dir}/scripts/install-k3s.sh" "${dir}/bin/kubectl" "${dir}/bin/helm"

  local name
  for name in postgres minio minio-client keycloak juicefs-csi juicefs-csi-liveness-probe juicefs-csi-node-driver-registrar juicefs-csi-provisioner juicefs-csi-resizer rwx-check; do
    write_fake_artifact "${dir}/images/oci/${name}.tar" "fake ${name} archive"
  done

  cat >"${lock}" <<EOF_LOCK
K3S_BINARY_URL=file://${dir}/bin/k3s
K3S_BINARY_SHA256=$(fake_file_sha "${dir}/bin/k3s")
K3S_INSTALL_SCRIPT_URL=file://${dir}/scripts/install-k3s.sh
K3S_INSTALL_SCRIPT_SHA256=$(fake_file_sha "${dir}/scripts/install-k3s.sh")
K3S_AIRGAP_IMAGES_URL=file://${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst
K3S_AIRGAP_IMAGES_SHA256=$(fake_file_sha "${dir}/images/k3s/k3s-airgap-images-amd64.tar.zst")
KUBECTL_BINARY_URL=file://${dir}/bin/kubectl
KUBECTL_BINARY_SHA256=$(fake_file_sha "${dir}/bin/kubectl")
HELM_BINARY_URL=file://${dir}/bin/helm
HELM_BINARY_SHA256=$(fake_file_sha "${dir}/bin/helm")
JUICEFS_CSI_ARTIFACT_URL=file://${dir}/charts/juicefs-csi.tgz
JUICEFS_CSI_ARTIFACT_SHA256=$(fake_file_sha "${dir}/charts/juicefs-csi.tgz")
POSTGRES_IMAGE=docker.io/library/postgres:16@sha256:${FAKE_DIGEST}
POSTGRES_ARCHIVE_URL=file://${dir}/images/oci/postgres.tar
POSTGRES_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/postgres.tar")
MINIO_IMAGE=docker.io/minio/minio:RELEASE.2025-09-07T16-13-09Z@sha256:${FAKE_DIGEST}
MINIO_ARCHIVE_URL=file://${dir}/images/oci/minio.tar
MINIO_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/minio.tar")
MINIO_CLIENT_IMAGE=docker.io/minio/mc:RELEASE.2025-08-13T08-35-41Z@sha256:${FAKE_DIGEST}
MINIO_CLIENT_ARCHIVE_URL=file://${dir}/images/oci/minio-client.tar
MINIO_CLIENT_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/minio-client.tar")
KEYCLOAK_IMAGE=quay.io/keycloak/keycloak:26.0.7@sha256:${FAKE_DIGEST}
KEYCLOAK_ARCHIVE_URL=file://${dir}/images/oci/keycloak.tar
KEYCLOAK_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/keycloak.tar")
JUICEFS_CSI_IMAGE=docker.io/juicedata/juicefs-csi-driver:v0.31.10@sha256:${FAKE_DIGEST}
JUICEFS_CSI_ARCHIVE_URL=file://${dir}/images/oci/juicefs-csi.tar
JUICEFS_CSI_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/juicefs-csi.tar")
JUICEFS_CSI_LIVENESS_PROBE_IMAGE=registry.k8s.io/sig-storage/livenessprobe:v2.12.0@sha256:${FAKE_DIGEST}
JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_URL=file://${dir}/images/oci/juicefs-csi-liveness-probe.tar
JUICEFS_CSI_LIVENESS_PROBE_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/juicefs-csi-liveness-probe.tar")
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_IMAGE=registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.9.0@sha256:${FAKE_DIGEST}
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_URL=file://${dir}/images/oci/juicefs-csi-node-driver-registrar.tar
JUICEFS_CSI_NODE_DRIVER_REGISTRAR_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/juicefs-csi-node-driver-registrar.tar")
JUICEFS_CSI_PROVISIONER_IMAGE=registry.k8s.io/sig-storage/csi-provisioner:v2.2.2@sha256:${FAKE_DIGEST}
JUICEFS_CSI_PROVISIONER_ARCHIVE_URL=file://${dir}/images/oci/juicefs-csi-provisioner.tar
JUICEFS_CSI_PROVISIONER_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/juicefs-csi-provisioner.tar")
JUICEFS_CSI_RESIZER_IMAGE=registry.k8s.io/sig-storage/csi-resizer:v1.9.0@sha256:${FAKE_DIGEST}
JUICEFS_CSI_RESIZER_ARCHIVE_URL=file://${dir}/images/oci/juicefs-csi-resizer.tar
JUICEFS_CSI_RESIZER_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/juicefs-csi-resizer.tar")
RWX_CHECK_IMAGE=docker.io/library/busybox:1.36.1@sha256:${FAKE_DIGEST}
RWX_CHECK_ARCHIVE_URL=file://${dir}/images/oci/rwx-check.tar
RWX_CHECK_ARCHIVE_SHA256=$(fake_file_sha "${dir}/images/oci/rwx-check.tar")
EOF_LOCK
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
OIDC_CLIENT_ID=
OIDC_BACKCHANNEL_BASE_URL=
JUICEFS_VOLUME_NAME=agentsmith-lite-files
JUICEFS_BUCKET=http://minio.agentsmith.svc.cluster.local:9000/agentsmith-lite-files
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
APP_SESSION_SECRET=app-session-secret-value-0123456789abcdef
S3_ACCESS_KEY=minio-access-key
S3_SECRET_KEY=minio-secret-value
JUICEFS_META_URL=postgres://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta
BUILTIN_ADMIN_INITIAL_PASSWORD=admin-secret-value
OIDC_CLIENT_SECRET=
OIDC_BOOTSTRAP_USERNAME=
OIDC_BOOTSTRAP_PASSWORD=
KEYCLOAK_DB_USER=
KEYCLOAK_DB_PASSWORD=
KEYCLOAK_DB_DATABASE=
KEYCLOAK_ADMIN_USERNAME=
KEYCLOAK_ADMIN_PASSWORD=
EOF_SECRETS
  chmod 0600 "${dir}/substrate.secrets.env"
}

write_valid_oidc_env_pair() {
  local dir="$1"
  write_valid_env_pair "${dir}"
  set_env_value "${dir}/substrate.env" "AUTH_MODE" "oidc"
  set_env_value "${dir}/substrate.env" "OIDC_ISSUER_URL" "https://auth.agentsmith.example.com/realms/agentsmith"
  set_env_value "${dir}/substrate.env" "OIDC_CLIENT_ID" "agentsmith-lite"
  set_env_value "${dir}/substrate.env" "OIDC_BACKCHANNEL_BASE_URL" "http://keycloak.agentsmith.svc.cluster.local:8080/realms/agentsmith"
  set_env_value "${dir}/substrate.secrets.env" "BUILTIN_ADMIN_INITIAL_PASSWORD" ""
  set_env_value "${dir}/substrate.secrets.env" "OIDC_CLIENT_SECRET" "oidc-client-secret-value"
  set_env_value "${dir}/substrate.secrets.env" "OIDC_BOOTSTRAP_USERNAME" "agentsmith-local"
  set_env_value "${dir}/substrate.secrets.env" "OIDC_BOOTSTRAP_PASSWORD" "oidc-bootstrap-password-value"
  set_env_value "${dir}/substrate.secrets.env" "KEYCLOAK_DB_USER" "keycloak"
  set_env_value "${dir}/substrate.secrets.env" "KEYCLOAK_DB_PASSWORD" "keycloak-db-password-value"
  set_env_value "${dir}/substrate.secrets.env" "KEYCLOAK_DB_DATABASE" "keycloak"
  set_env_value "${dir}/substrate.secrets.env" "KEYCLOAK_ADMIN_USERNAME" "admin"
  set_env_value "${dir}/substrate.secrets.env" "KEYCLOAK_ADMIN_PASSWORD" "keycloak-admin-password-value"
  chmod 0600 "${dir}/substrate.secrets.env"
}

write_live_kubectl_stub() {
  local file="$1"
  mkdir -p "$(dirname "${file}")"
  cat >"${file}" <<'EOF_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
: "${KUBECTL_LOG:?KUBECTL_LOG is required}"
printf 'kubectl %s\n' "$*" >>"${KUBECTL_LOG}"

if [[ "${KUBECTL_FAIL_MINIO_BUCKET_WAIT:-}" == "true" && "$*" == *"-n agentsmith wait --for=condition=complete job/agentsmith-lite-minio-bucket-init"* ]]; then
  printf 'bucket init wait timed out\n' >&2
  exit 1
fi
if [[ "${KUBECTL_FAIL_POSTGRES_INIT_WAIT:-}" == "true" && "$*" == *"-n agentsmith wait --for=condition=complete job/agentsmith-lite-postgres-init"* ]]; then
  printf 'postgres init wait timed out\n' >&2
  exit 1
fi

juicefs_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

case "$*" in
  *"get storageclass agentsmith-lite-juicefs-rwx -o jsonpath={.provisioner}"*)
    printf '%s' "${JUICEFS_FAKE_SC_PROVISIONER:-csi.juicefs.com}"
    ;;
  *"get storageclass agentsmith-lite-juicefs-rwx -o jsonpath="*"provisioner-secret-namespace"*)
    printf '%s' "${JUICEFS_FAKE_SC_PROVISIONER_SECRET_NAMESPACE:-agentsmith}"
    ;;
  *"get storageclass agentsmith-lite-juicefs-rwx -o jsonpath="*"provisioner-secret-name"*)
    printf '%s' "${JUICEFS_FAKE_SC_PROVISIONER_SECRET_NAME:-agentsmith-lite-juicefs}"
    ;;
  *"get storageclass agentsmith-lite-juicefs-rwx -o jsonpath="*"node-publish-secret-namespace"*)
    printf '%s' "${JUICEFS_FAKE_SC_NODE_SECRET_NAMESPACE:-agentsmith}"
    ;;
  *"get storageclass agentsmith-lite-juicefs-rwx -o jsonpath="*"node-publish-secret-name"*)
    printf '%s' "${JUICEFS_FAKE_SC_NODE_SECRET_NAME:-agentsmith-lite-juicefs}"
    ;;
  *"-n agentsmith get secret agentsmith-lite-juicefs -o jsonpath="*"name"*)
    juicefs_b64 "${JUICEFS_FAKE_SECRET_NAME_VALUE:-agentsmith-lite-files}"
    ;;
  *"-n agentsmith get secret agentsmith-lite-juicefs -o jsonpath="*"metaurl"*)
    juicefs_b64 "${JUICEFS_FAKE_SECRET_METAURL:-postgres://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta}"
    ;;
  *"-n agentsmith get secret agentsmith-lite-juicefs -o jsonpath="*"storage"*)
    juicefs_b64 "${JUICEFS_FAKE_SECRET_STORAGE:-s3}"
    ;;
  *"-n agentsmith get secret agentsmith-lite-juicefs -o jsonpath="*"bucket"*)
    juicefs_b64 "${JUICEFS_FAKE_SECRET_BUCKET:-http://minio.agentsmith.svc.cluster.local:9000/agentsmith-lite-files}"
    ;;
  *"-n agentsmith get secret agentsmith-lite-juicefs -o jsonpath="*"access-key"*)
    juicefs_b64 "${JUICEFS_FAKE_SECRET_ACCESS_KEY:-minio-access-key}"
    ;;
  *"-n agentsmith get secret agentsmith-lite-juicefs -o jsonpath="*"secret-key"*)
    juicefs_b64 "${JUICEFS_FAKE_SECRET_SECRET_KEY:-minio-secret-value}"
    ;;
  *"-n agentsmith get pvc agentsmith-lite-files -o jsonpath={.spec.storageClassName}"*)
    printf '%s' "${JUICEFS_FAKE_PVC_STORAGE_CLASS:-agentsmith-lite-juicefs-rwx}"
    ;;
  *"-n agentsmith get pvc agentsmith-lite-files -o jsonpath="*"accessModes"*)
    printf '%s' "${JUICEFS_FAKE_PVC_ACCESS_MODES:-ReadWriteMany}"
    ;;
  *"-n agentsmith get pvc agentsmith-lite-files -o jsonpath={.status.phase}"*)
    printf '%s' "${JUICEFS_FAKE_PVC_PHASE:-Bound}"
    ;;
  *" logs job/asl-pg-probe-"*)
    printf 'agentsmith-lite-postgres-probe passed\n'
    ;;
  *" logs job/agentsmith-lite-postgres-init"*)
    printf '%s\n' "${KUBECTL_POSTGRES_INIT_LOGS:-postgres init ready}"
    ;;
  *" logs job/agentsmith-lite-minio-bucket-init"*)
    printf 'minio bucket ready\n'
    ;;
  *"-n agentsmith logs -l job-name=agentsmith-lite-postgres-init --all-containers --tail=-1"*)
    printf '%s\n' "${KUBECTL_POSTGRES_INIT_SELECTOR_LOGS:-postgres init failed log}"
    ;;
  *"-n agentsmith describe job agentsmith-lite-postgres-init"*)
    printf 'postgres init describe\n'
    ;;
  *"-n agentsmith logs -l job-name=agentsmith-lite-minio-bucket-init --all-containers --tail=-1"*)
    printf 'bucket init failed log\n'
    ;;
  *"-n agentsmith describe job agentsmith-lite-minio-bucket-init"*)
    printf 'bucket init describe\n'
    ;;
  *" logs job/agentsmith-lite-juicefs-format"*)
    printf 'agentsmith-lite-juicefs-format: ok\n'
    ;;
  *" logs job/agentsmith-lite-s3-probe-"*)
    printf 'agentsmith-lite-s3-probe passed\n'
    ;;
  *" logs job/agentsmith-lite-rwx-check-"*)
    printf 'agentsmith-lite-rwx-check passed\n'
    ;;
esac
exit 0
EOF_KUBECTL
  chmod +x "${file}"
}

write_live_helm_stub() {
  local file="$1"
  mkdir -p "$(dirname "${file}")"
  cat >"${file}" <<'EOF_HELM'
#!/usr/bin/env bash
set -euo pipefail
: "${HELM_LOG:?HELM_LOG is required}"
printf 'helm %s\n' "$*" >>"${HELM_LOG}"
exit 0
EOF_HELM
  chmod +x "${file}"
}

run_live_doctor() {
  local env_dir="$1"
  local kubectl="$2"
  local kubectl_log="$3"
  local out="$4"
  shift 4

  KUBECTL_BIN="${kubectl}" \
    KUBECTL_LOG="${kubectl_log}" \
    POSTGRES_PROBE_RUN_ID="pgprobe" \
    S3_PROBE_RUN_ID="s3probe" \
    RWX_CHECK_RUN_ID="rwxprobe" \
    "${ROOT_DIR}/scripts/doctor.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env" \
    --postgres-probe-image "${POSTGRES_PROBE_IMAGE}" \
    --s3-probe-image "${S3_PROBE_IMAGE}" \
    --rwx-check-image "${RWX_CHECK_IMAGE}" \
    >"${out}" 2>&1
}

test_env_secrets_contract() {
  local env_dir="${TMP_DIR}/env-contract"
  local out="${TMP_DIR}/validate-env.out"

  write_valid_env_pair "${env_dir}"
  "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env" \
    >"${out}" 2>&1

  assert_contains "${out}" "validated substrate env contract"
  assert_contains "${out}" "secret POSTGRES_APP_URL fingerprint=sha256:"
  assert_not_contains "${out}" "postgres-secret-value"
  assert_not_contains "${out}" "minio-secret-value"
  pass "env/secrets contract validates and redacts raw values"
}

test_oidc_env_contract() {
  local env_dir="${TMP_DIR}/oidc-env-contract"
  local out="${TMP_DIR}/oidc-validate-env.out"

  write_valid_oidc_env_pair "${env_dir}"
  "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env" \
    >"${out}" 2>&1

  assert_contains "${out}" "validated substrate env contract"
  assert_contains "${out}" "secret OIDC_CLIENT_SECRET fingerprint=sha256:"
  assert_not_contains "${out}" "oidc-client-secret-value"
  pass "OIDC env/secrets contract validates and redacts raw client secret"
}

test_oidc_env_contract_rejects_missing_required_values() {
  local env_dir="${TMP_DIR}/oidc-env-contract-missing-issuer"
  local out="${TMP_DIR}/oidc-missing-issuer.out"
  write_valid_oidc_env_pair "${env_dir}"
  set_env_value "${env_dir}/substrate.env" "OIDC_ISSUER_URL" ""
  assert_command_fails_contains \
    "${out}" \
    "substrate.env key OIDC_ISSUER_URL must not be empty" \
    "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env"

  env_dir="${TMP_DIR}/oidc-env-contract-missing-secret"
  out="${TMP_DIR}/oidc-missing-secret.out"
  write_valid_oidc_env_pair "${env_dir}"
  set_env_value "${env_dir}/substrate.secrets.env" "OIDC_CLIENT_SECRET" ""
  assert_command_fails_contains \
    "${out}" \
    "substrate.secrets.env key OIDC_CLIENT_SECRET must not be empty" \
    "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env"

  pass "OIDC env/secrets contract rejects missing issuer or client secret"
}

test_builtin_admin_rejects_oidc_bootstrap_credentials() {
  local env_dir="${TMP_DIR}/builtin-admin-oidc-bootstrap"
  local out="${TMP_DIR}/builtin-admin-oidc-bootstrap.out"

  write_valid_env_pair "${env_dir}"
  set_env_value "${env_dir}/substrate.secrets.env" "OIDC_BOOTSTRAP_USERNAME" "agentsmith-local"
  assert_command_fails_contains \
    "${out}" \
    "OIDC_BOOTSTRAP_USERNAME must be empty when AUTH_MODE=builtin_admin" \
    "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env"

  write_valid_env_pair "${env_dir}"
  set_env_value "${env_dir}/substrate.secrets.env" "OIDC_BOOTSTRAP_PASSWORD" "oidc-bootstrap-password-value"
  assert_command_fails_contains \
    "${out}" \
    "OIDC_BOOTSTRAP_PASSWORD must be empty when AUTH_MODE=builtin_admin" \
    "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env"

  pass "builtin admin env rejects OIDC bootstrap credentials"
}

test_existing_cloud_oidc_reads_default_env_names() {
  local cache="${TMP_DIR}/existing-cloud-oidc-cache"
  local output="${TMP_DIR}/existing-cloud-oidc-out"
  local config="${TMP_DIR}/existing-cloud-oidc.yaml"
  local out="${TMP_DIR}/existing-cloud-oidc-install.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/existing-cloud-oidc-cache.out" 2>&1
  cat >"${config}" <<'EOF_CONFIG'
mode: existing-cloud
kubernetes:
  namespace: agentsmith
  kubeconfigPath: /secure/path/kubeconfig
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
  mode: oidc
ingress:
  publicBaseUrl: https://agentsmith.example.com
  ingressClass: ""
  tlsSecretName: ""
EOF_CONFIG

  POSTGRES_APP_URL='postgresql://agentsmith:secret@postgres.example.com:5432/agentsmith_lite' \
    JUICEFS_META_URL='postgres://juicefs:secret@postgres.example.com:5432/juicefs_meta' \
    S3_ACCESS_KEY='existing-cloud-access-key' \
    S3_SECRET_KEY='existing-cloud-secret-key' \
    APP_SESSION_SECRET='existing-cloud-app-session-secret-value' \
    OIDC_ISSUER_URL='https://auth.agentsmith.example.com/realms/agentsmith' \
    OIDC_CLIENT_ID='agentsmith-lite' \
    OIDC_BACKCHANNEL_BASE_URL='http://keycloak.agentsmith.svc.cluster.local:8080/realms/agentsmith' \
    OIDC_CLIENT_SECRET='existing-cloud-oidc-secret' \
    "${ROOT_DIR}/scripts/install-online.sh" \
      --cache "${cache}" \
      --config "${config}" \
      --output "${output}" \
      --dry-run \
      --force \
      >"${out}" 2>&1

  assert_contains "${output}/substrate.env" "AUTH_MODE=oidc"
  assert_contains "${output}/substrate.env" "OIDC_ISSUER_URL=https://auth.agentsmith.example.com/realms/agentsmith"
  assert_contains "${output}/substrate.env" "OIDC_CLIENT_ID=agentsmith-lite"
  assert_contains "${output}/substrate.env" "OIDC_BACKCHANNEL_BASE_URL=http://keycloak.agentsmith.svc.cluster.local:8080/realms/agentsmith"
  assert_contains "${output}/substrate.env" "JUICEFS_BUCKET=https://s3.us-east-1.amazonaws.com/agentsmith-lite-files"
  assert_not_contains "${output}/substrate.env" "JUICEFS_BUCKET=s3://agentsmith-lite-files/agentsmith-lite/"
  assert_contains "${output}/substrate.secrets.env" "JUICEFS_META_URL=postgres://juicefs:secret@postgres.example.com:5432/juicefs_meta"
  assert_contains "${output}/substrate.secrets.env" "OIDC_CLIENT_SECRET=existing-cloud-oidc-secret"
  assert_contains "${output}/substrate.secrets.env" "OIDC_BOOTSTRAP_USERNAME="
  assert_contains "${output}/substrate.secrets.env" "OIDC_BOOTSTRAP_PASSWORD="
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_DB_USER="
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_DB_PASSWORD="
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_DB_DATABASE="
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_ADMIN_USERNAME="
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_ADMIN_PASSWORD="
  assert_not_contains "${out}" "existing-cloud-oidc-secret"
  pass "existing-cloud OIDC config reads default env names"
}

test_existing_cloud_rejects_postgresql_juicefs_meta_url() {
  local cache="${TMP_DIR}/existing-cloud-postgresql-meta-cache"
  local output="${TMP_DIR}/existing-cloud-postgresql-meta-out"
  local out="${TMP_DIR}/existing-cloud-postgresql-meta.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/existing-cloud-postgresql-meta-cache.out" 2>&1
  POSTGRES_APP_URL='postgresql://agentsmith:secret@postgres.example.com:5432/agentsmith_lite' \
    JUICEFS_META_URL='postgresql://juicefs:secret@postgres.example.com:5432/juicefs_meta' \
    S3_ACCESS_KEY='existing-cloud-access-key' \
    S3_SECRET_KEY='existing-cloud-secret-key' \
    APP_SESSION_SECRET='existing-cloud-app-session-secret-value' \
    OIDC_ISSUER_URL='https://auth.agentsmith.example.com/realms/agentsmith' \
    OIDC_CLIENT_ID='agentsmith-lite' \
    OIDC_BACKCHANNEL_BASE_URL='http://keycloak.agentsmith.svc.cluster.local:8080/realms/agentsmith' \
    OIDC_CLIENT_SECRET='existing-cloud-oidc-secret' \
    assert_command_fails_contains \
      "${out}" \
      "JUICEFS_META_URL must start with postgres://" \
      "${ROOT_DIR}/scripts/install-online.sh" \
      --cache "${cache}" \
      --config "${ROOT_DIR}/config/substrates.existing-cloud.example.yaml" \
      --output "${output}" \
      --dry-run \
      --force

  pass "existing-cloud rejects postgresql:// JuiceFS metadata URLs"
}

test_self_hosted_default_kube_context_is_empty() {
  local cache="${TMP_DIR}/self-hosted-empty-context-cache"
  local output="${TMP_DIR}/self-hosted-empty-context-out"
  local out="${TMP_DIR}/self-hosted-empty-context-install.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/self-hosted-empty-context-cache.out" 2>&1
  "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${output}" \
    --dry-run \
    --force \
    >"${out}" 2>&1

  assert_contains "${output}/substrate.env" "KUBE_CONTEXT="
  assert_not_contains "${output}/substrate.env" "KUBE_CONTEXT=agentsmith-lite"
  pass "self-hosted default env leaves KUBE_CONTEXT empty"
}

test_self_hosted_default_juicefs_bucket_is_http_bucket_url() {
  local cache="${TMP_DIR}/self-hosted-juicefs-bucket-cache"
  local output="${TMP_DIR}/self-hosted-juicefs-bucket-out"
  local out="${TMP_DIR}/self-hosted-juicefs-bucket-install.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/self-hosted-juicefs-bucket-cache.out" 2>&1
  "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${output}" \
    --dry-run \
    --force \
    >"${out}" 2>&1

  assert_contains "${output}/substrate.env" "JUICEFS_BUCKET=http://minio.agentsmith.svc.cluster.local:9000/agentsmith-lite-files"
  assert_not_contains "${output}/substrate.env" "JUICEFS_BUCKET=s3://agentsmith-lite-files/agentsmith-lite/"
  pass "self-hosted default JuiceFS bucket is the HTTP MinIO bucket URL"
}

test_self_hosted_default_juicefs_meta_url_uses_postgres_scheme() {
  local cache="${TMP_DIR}/self-hosted-juicefs-meta-cache"
  local output="${TMP_DIR}/self-hosted-juicefs-meta-out"
  local out="${TMP_DIR}/self-hosted-juicefs-meta-install.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/self-hosted-juicefs-meta-cache.out" 2>&1
  JUICEFS_META_PASSWORD="juicefs-secret-value" \
    "${ROOT_DIR}/scripts/install-online.sh" \
      --cache "${cache}" \
      --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
      --output "${output}" \
      --dry-run \
      --force \
      >"${out}" 2>&1

  assert_contains "${output}/substrate.secrets.env" "JUICEFS_META_URL=postgres://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta"
  assert_not_contains "${output}/substrate.secrets.env" "JUICEFS_META_URL=postgresql://"
  pass "self-hosted default JuiceFS metadata URL uses postgres:// with password"
}

test_juicefs_bucket_contract_rejects_s3_prefix_url() {
  local env_dir="${TMP_DIR}/juicefs-bucket-s3-prefix"
  local out="${TMP_DIR}/juicefs-bucket-s3-prefix.out"

  write_valid_env_pair "${env_dir}"
  set_env_value "${env_dir}/substrate.env" "JUICEFS_BUCKET" "s3://agentsmith-lite-files/agentsmith-lite/"
  assert_command_fails_contains \
    "${out}" \
    "JUICEFS_BUCKET must be a full http(s) bucket URL" \
    "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env"

  pass "JuiceFS bucket contract rejects s3 prefix URLs"
}

test_juicefs_meta_url_contract_requires_postgres_scheme() {
  local env_dir="${TMP_DIR}/juicefs-meta-postgresql"
  local env_out="${TMP_DIR}/juicefs-meta-postgresql-env.out"
  local juicefs_out="${TMP_DIR}/juicefs-meta-postgresql-juicefs.out"
  local missing_password_out="${TMP_DIR}/juicefs-meta-missing-password.out"
  local accept_out="${TMP_DIR}/juicefs-meta-postgres-accept.out"

  write_valid_env_pair "${env_dir}"
  set_env_value "${env_dir}/substrate.secrets.env" "JUICEFS_META_URL" "postgresql://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta"
  assert_command_fails_contains \
    "${env_out}" \
    "JUICEFS_META_URL must be postgres://user:password@host:port/db" \
    "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env"
  assert_command_fails_contains \
    "${juicefs_out}" \
    "JUICEFS_META_URL must be postgres://user:password@host:port/db" \
    "${ROOT_DIR}/scripts/validate-juicefs-contract.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env"

  set_env_value "${env_dir}/substrate.secrets.env" "JUICEFS_META_URL" "postgres://juicefs@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta"
  assert_command_fails_contains \
    "${missing_password_out}" \
    "JUICEFS_META_URL must be postgres://user:password@host:port/db" \
    "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env"

  set_env_value "${env_dir}/substrate.secrets.env" "JUICEFS_META_URL" "postgres://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta"
  "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env" \
    >"${accept_out}" 2>&1
  "${ROOT_DIR}/scripts/validate-juicefs-contract.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env" \
    >>"${accept_out}" 2>&1
  assert_contains "${accept_out}" "validated substrate env contract"
  assert_contains "${accept_out}" "JuiceFS CSI contract validated"
  pass "JuiceFS metadata contract rejects postgresql:// and missing passwords, accepts postgres://"
}

test_json_schemas_match_juicefs_contract() {
  local env_schema="${ROOT_DIR}/schemas/substrate.env.v1.schema.json"
  local secrets_schema="${ROOT_DIR}/schemas/substrate.secrets.env.v1.schema.json"
  local config_schema="${ROOT_DIR}/schemas/substrates-config.v1.schema.json"

  assert_contains "${env_schema}" '"JUICEFS_BUCKET": { "type": "string", "pattern": "^https?://'
  assert_not_contains "${env_schema}" '"JUICEFS_BUCKET": { "type": "string", "pattern": "^s3://" }'
  assert_contains "${secrets_schema}" '"pattern": "^postgres://",'
  assert_not_contains "${secrets_schema}" '"JUICEFS_META_URL": { "type": "string", "pattern": "^postgres(ql)?://"'
  assert_contains "${secrets_schema}" '"KEYCLOAK_DB_USER": {'
  assert_contains "${secrets_schema}" '"KEYCLOAK_DB_PASSWORD": {'
  assert_contains "${secrets_schema}" '"KEYCLOAK_DB_DATABASE": {'
  assert_contains "${secrets_schema}" '"KEYCLOAK_ADMIN_USERNAME": {'
  assert_contains "${secrets_schema}" '"KEYCLOAK_ADMIN_PASSWORD": {'
  assert_contains "${secrets_schema}" "Substrate-only local Keycloak database password; do not inject into app workload env."
  assert_contains "${config_schema}" '"bucket": { "type": "string", "pattern": "^https?://'
  pass "JSON schemas match JuiceFS bucket and metadata URL contract"
}

test_self_hosted_force_reuses_existing_persistent_secrets() {
  local cache="${TMP_DIR}/self-hosted-force-reuse-cache"
  local output="${TMP_DIR}/self-hosted-force-reuse-out"
  local first_out="${TMP_DIR}/self-hosted-force-reuse-first.out"
  local second_out="${TMP_DIR}/self-hosted-force-reuse-second.out"
  local override_out="${TMP_DIR}/self-hosted-force-reuse-override.out"
  local snapshot="${TMP_DIR}/self-hosted-force-reuse.snapshot"
  local key

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/self-hosted-force-reuse-cache.out" 2>&1
  "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${output}" \
    --dry-run \
    --force \
    >"${first_out}" 2>&1
  set_env_value "${output}/substrate.secrets.env" "BUILTIN_ADMIN_INITIAL_PASSWORD" "admin-force-stable-password-0123456789"

  : >"${snapshot}"
  for key in POSTGRES_APP_URL JUICEFS_META_URL S3_ACCESS_KEY S3_SECRET_KEY APP_SESSION_SECRET OIDC_CLIENT_SECRET OIDC_BOOTSTRAP_PASSWORD BUILTIN_ADMIN_INITIAL_PASSWORD OIDC_BOOTSTRAP_USERNAME KEYCLOAK_DB_USER KEYCLOAK_DB_PASSWORD KEYCLOAK_DB_DATABASE KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD; do
    printf '%s=%s\n' "${key}" "$(env_file_value "${output}/substrate.secrets.env" "${key}")" >>"${snapshot}"
  done

  "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${output}" \
    --dry-run \
    --force \
    >"${second_out}" 2>&1
  while IFS= read -r key; do
    assert_contains "${output}/substrate.secrets.env" "${key}"
  done <"${snapshot}"

  S3_SECRET_KEY="explicit-s3-secret-value" \
    OIDC_BOOTSTRAP_USERNAME="agentsmith-explicit" \
    KEYCLOAK_DB_PASSWORD="explicit-keycloak-db-password" \
    KEYCLOAK_ADMIN_USERNAME="admin-explicit" \
    "${ROOT_DIR}/scripts/install-online.sh" \
      --cache "${cache}" \
      --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
      --output "${output}" \
      --dry-run \
      --force \
      >"${override_out}" 2>&1
  assert_contains "${output}/substrate.secrets.env" "S3_SECRET_KEY=explicit-s3-secret-value"
  assert_contains "${output}/substrate.secrets.env" "OIDC_BOOTSTRAP_USERNAME=agentsmith-explicit"
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_DB_PASSWORD=explicit-keycloak-db-password"
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_ADMIN_USERNAME=admin-explicit"
  pass "self-hosted --force reuses persistent secrets unless env overrides"
}

test_self_hosted_force_rejects_partial_or_invalid_output() {
  local cache="${TMP_DIR}/self-hosted-force-invalid-cache"
  local source_dir="${TMP_DIR}/self-hosted-force-invalid-source"
  local only_env="${TMP_DIR}/self-hosted-force-only-env"
  local only_secrets="${TMP_DIR}/self-hosted-force-only-secrets"
  local invalid="${TMP_DIR}/self-hosted-force-invalid-secrets"
  local out="${TMP_DIR}/self-hosted-force-invalid.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/self-hosted-force-invalid-cache.out" 2>&1
  write_valid_oidc_env_pair "${source_dir}"

  mkdir -p "${only_env}"
  cp "${source_dir}/substrate.env" "${only_env}/substrate.env"
  assert_command_fails_contains \
    "${out}" \
    "self-hosted output env files are incomplete" \
    "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${only_env}" \
    --dry-run \
    --force

  mkdir -p "${only_secrets}"
  cp "${source_dir}/substrate.secrets.env" "${only_secrets}/substrate.secrets.env"
  assert_command_fails_contains \
    "${out}" \
    "self-hosted output env files are incomplete" \
    "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${only_secrets}" \
    --dry-run \
    --force

  write_valid_oidc_env_pair "${invalid}"
  set_env_value "${invalid}/substrate.secrets.env" "S3_SECRET_KEY" ""
  assert_command_fails_contains \
    "${out}" \
    "existing self-hosted output env files do not validate" \
    "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${invalid}" \
    --dry-run \
    --force
  assert_contains "${out}" "substrate.secrets.env key S3_SECRET_KEY must not be empty"
  pass "self-hosted --force rejects partial output and invalid secrets"
}

test_self_hosted_skip_k3s_requires_readable_kubeconfig() {
  local cache="${TMP_DIR}/skip-k3s-contract-cache"
  local output="${TMP_DIR}/skip-k3s-missing-kubeconfig-out"
  local config="${TMP_DIR}/skip-k3s-missing-kubeconfig.yaml"
  local out="${TMP_DIR}/skip-k3s-missing-kubeconfig.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/skip-k3s-contract-cache.out" 2>&1
  cat >"${config}" <<'EOF_CONFIG'
mode: self-hosted
kubernetes:
  namespace: agentsmith
  skipK3s: true
objectStorage:
  provider: minio
  bucket: agentsmith-lite-files
juicefs:
  storageClass: agentsmith-lite-juicefs-rwx
  pvcName: agentsmith-lite-files
auth:
  mode: builtin_admin
ingress:
  publicBaseUrl: http://localhost:3000
EOF_CONFIG

  assert_command_fails_contains \
    "${out}" \
    "config contract requires kubernetes.kubeconfigPath" \
    "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${config}" \
    --output "${output}" \
    --dry-run \
    --force

  config="${TMP_DIR}/skip-k3s-unreadable-kubeconfig.yaml"
  out="${TMP_DIR}/skip-k3s-unreadable-kubeconfig.out"
  cat >"${config}" <<'EOF_CONFIG'
mode: self-hosted
kubernetes:
  namespace: agentsmith
  skipK3s: true
  kubeconfigPath: /no/such/kubeconfig
objectStorage:
  provider: minio
  bucket: agentsmith-lite-files
juicefs:
  storageClass: agentsmith-lite-juicefs-rwx
  pvcName: agentsmith-lite-files
auth:
  mode: builtin_admin
ingress:
  publicBaseUrl: http://localhost:3000
EOF_CONFIG

  assert_command_fails_contains \
    "${out}" \
    "config contract kubernetes.kubeconfigPath must be readable when kubernetes.skipK3s=true" \
    "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${config}" \
    --output "${output}" \
    --dry-run \
    --force

  pass "self-hosted skipK3s config requires readable kubeconfigPath"
}

test_self_hosted_skip_k3s_live_uses_existing_cluster_chain() {
  local artifacts="${TMP_DIR}/skip-k3s-live-artifacts"
  local lock="${TMP_DIR}/skip-k3s-live-artifacts.env"
  local cache="${TMP_DIR}/skip-k3s-live-cache"
  local output="${TMP_DIR}/skip-k3s-live-out"
  local config="${TMP_DIR}/skip-k3s-live.yaml"
  local kubeconfig="${TMP_DIR}/kind-kubeconfig"
  local kubectl_log="${TMP_DIR}/skip-k3s-live-kubectl.log"
  local helm_log="${TMP_DIR}/skip-k3s-live-helm.log"
  local out="${TMP_DIR}/skip-k3s-live.out"

  write_fake_p1_artifact_lock "${artifacts}" "${lock}"
  "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock}" --output "${cache}" --force >"${TMP_DIR}/skip-k3s-live-cache.out" 2>&1
  write_fake_artifact "${kubeconfig}" "apiVersion: v1"
  cat >"${config}" <<EOF_CONFIG
mode: self-hosted
kubernetes:
  namespace: agentsmith
  skipK3s: true
  kubeconfigPath: ${kubeconfig}
  context: kind-agentsmith
objectStorage:
  provider: minio
  bucket: agentsmith-lite-files
juicefs:
  storageClass: agentsmith-lite-juicefs-rwx
  pvcName: agentsmith-lite-files
auth:
  mode: builtin_admin
ingress:
  publicBaseUrl: http://localhost:3000
EOF_CONFIG

  local status=0
  set +e
  KUBECTL_LOG="${kubectl_log}" \
    HELM_LOG="${helm_log}" \
    S3_ACCESS_KEY="minio-access-key" \
    S3_SECRET_KEY="minio-secret-value" \
    JUICEFS_META_PASSWORD="juicefs-secret-value" \
    POSTGRES_PROBE_RUN_ID="pgprobe" \
    S3_PROBE_RUN_ID="s3probe" \
    RWX_CHECK_RUN_ID="rwxprobe" \
    "${ROOT_DIR}/scripts/install-online.sh" \
      --cache "${cache}" \
      --config "${config}" \
      --output "${output}" \
      --force \
      >"${out}" 2>&1
  status=$?
  set -e
  if [[ "${status}" -ne 0 ]]; then
    printf 'skipK3s live install output:\n' >&2
    sed -n '1,260p' "${out}" >&2
    fail "skipK3s live install should exit 0, got ${status}"
  fi

  assert_contains "${out}" "kubernetes.skipK3s=true; using existing kubeconfig and skipping k3s installer plus k3s image import"
  assert_contains "${output}/substrate.env" "KUBERNETES_SKIP_K3S=true"
  assert_contains "${output}/substrate.env" "KUBECONFIG_PATH=${kubeconfig}"
  assert_contains "${output}/substrate.env" "KUBE_CONTEXT=kind-agentsmith"
  assert_contains "${kubectl_log}" "--kubeconfig ${kubeconfig} --context kind-agentsmith apply -f ${output}/rendered/offline-install/namespace.yaml"
  assert_contains "${kubectl_log}" "apply -f ${output}/rendered/offline-install/postgres.yaml"
  assert_contains "${kubectl_log}" "apply -f ${output}/rendered/offline-install/minio.yaml"
  assert_contains "${kubectl_log}" "apply -f ${output}/rendered/offline-install/juicefs-storageclass-pvc.yaml"
  assert_contains "${helm_log}" "--kubeconfig ${kubeconfig} --kube-context kind-agentsmith upgrade --install juicefs-csi-driver"
  assert_not_contains "${helm_log}" "--context kind-agentsmith"
  assert_contains "${out}" "doctor passed"
  pass "self-hosted skipK3s live install skips k3s/import and runs service chain"
}

test_minio_bucket_job_uses_mc_alias_and_retry() {
  local manifest="${ROOT_DIR}/manifests/minio/bucket-init-job.yaml"

  assert_not_contains "${manifest}" "awk"
  assert_not_contains "${manifest}" "config.json"
  assert_contains "${manifest}" 'mc alias set agentsmith-minio "$S3_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4'
  assert_contains "${manifest}" 'while [ "${attempt}" -lt 30 ]; do'
  assert_contains "${manifest}" 'mc mb --ignore-existing "agentsmith-minio/$S3_BUCKET"'
  assert_contains "${manifest}" 'mc stat "agentsmith-minio/$S3_BUCKET"'
  pass "MinIO bucket init Job uses mc alias and bounded retry without awk config rendering"
}

test_s3_probe_job_uses_mc_alias_and_object_lifecycle() {
  local manifest="${TMP_DIR}/s3-probe-job.yaml"

  s3_probe_render_job \
    "${manifest}" \
    "agentsmith-lite-s3-probe-test" \
    "agentsmith-lite-s3-probe-secret" \
    "agentsmith" \
    "${S3_PROBE_IMAGE}" \
    "s3probe"

  assert_not_contains "${manifest}" "awk"
  assert_not_contains "${manifest}" "json_escape_env"
  assert_not_contains "${manifest}" "config.json"
  assert_contains "${manifest}" 'case "${S3_FORCE_PATH_STYLE}" in'
  assert_contains "${manifest}" 'true) path_style="on" ;;'
  assert_contains "${manifest}" 'false) path_style="off" ;;'
  assert_contains "${manifest}" '*) fail_probe "invalid S3_FORCE_PATH_STYLE" ;;'
  assert_contains "${manifest}" 'mc --config-dir "${MC_CONFIG_DIR}" alias set "${alias_name}" "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" --api S3v4 --path "${path_style}"'
  assert_contains "${manifest}" 'mc --config-dir "${MC_CONFIG_DIR}" pipe "${object_uri}"'
  assert_contains "${manifest}" 'mc --config-dir "${MC_CONFIG_DIR}" cat "${object_uri}"'
  assert_contains "${manifest}" 'mc --config-dir "${MC_CONFIG_DIR}" rm --quiet --force "${object_uri}"'
  assert_contains "${manifest}" 'mc --config-dir "${MC_CONFIG_DIR}" stat "${object_uri}"'
  pass "S3 probe Job uses mc alias and object lifecycle operations"
}

test_minio_statefulset_has_health_probes() {
  local manifest="${ROOT_DIR}/manifests/minio/minio.yaml"

  assert_contains "${manifest}" "startupProbe:"
  assert_contains "${manifest}" "readinessProbe:"
  assert_contains "${manifest}" "path: /minio/health/ready"
  assert_contains "${manifest}" "port: api"
  pass "MinIO StatefulSet probes readiness endpoint"
}

test_juicefs_format_job_surfaces_failure_logs_and_checks_storage() {
  local manifest="${ROOT_DIR}/manifests/juicefs-csi/format-job.yaml"
  local meta_arg_count

  assert_not_contains "${manifest}" "JFS_NO_CHECK_OBJECT_STORAGE=1"
  assert_contains "${manifest}" 'cat "$format_log" >&2'
  assert_contains "${manifest}" 'cat "$config_log" >&2'
  assert_not_contains "${manifest}" "safe_meta_url"
  assert_not_contains "${manifest}" "META_PASSWORD"
  assert_contains "${manifest}" 'meta_url="$JUICEFS_META_URL"'
  meta_arg_count="$(grep -Fc '"$meta_url"' "${manifest}" || true)"
  [[ "${meta_arg_count}" -eq 2 ]] || fail "JuiceFS format Job should pass the same meta_url to juicefs format and juicefs config"
  pass "JuiceFS format Job checks object storage and prints failure logs"
}

test_postgres_statefulset_has_pg_isready_readiness_probe() {
  local manifest="${ROOT_DIR}/manifests/postgres/postgres.yaml"

  assert_contains "${manifest}" "readinessProbe:"
  assert_contains "${manifest}" "pg_isready"
  pass "Postgres StatefulSet probes readiness with pg_isready"
}

test_postgres_init_complete_does_not_require_log_sentinel() {
  local cache="${TMP_DIR}/postgres-init-complete-cache"
  local env_dir="${TMP_DIR}/postgres-init-complete-env"
  local render_dir="${TMP_DIR}/postgres-init-complete-render"
  local kubectl_log="${TMP_DIR}/postgres-init-complete-kubectl.log"
  local out="${TMP_DIR}/postgres-init-complete.out"
  local delete_count
  local status=0

  mkdir -p "${cache}/bin" "${render_dir}"
  write_valid_env_pair "${env_dir}"
  write_live_kubectl_stub "${cache}/bin/kubectl"
  write_fake_artifact "${render_dir}/postgres-init-job.yaml" "kind: Job"

  set +e
  KUBECTL_LOG="${kubectl_log}" \
    KUBECTL_POSTGRES_INIT_LOGS="postgres init completed without sentinel" \
    bash -c 'set -euo pipefail; source "$1"; offline_install_init_postgres_databases "$2" "$3" "$4"' \
      _ \
      "${ROOT_DIR}/scripts/lib/offline_install.sh" \
      "${cache}" \
      "${env_dir}/substrate.env" \
      "${render_dir}" \
      >"${out}" 2>&1
  status=$?
  set -e
  if [[ "${status}" -ne 0 ]]; then
    printf 'postgres init complete output:\n' >&2
    sed -n '1,220p' "${out}" >&2
    fail "postgres init complete should exit 0, got ${status}"
  fi

  assert_contains "${kubectl_log}" "wait --for=condition=complete job/agentsmith-lite-postgres-init --timeout=120s"
  assert_not_contains "${kubectl_log}" "logs job/agentsmith-lite-postgres-init"
  delete_count="$(grep -Fc "delete job agentsmith-lite-postgres-init" "${kubectl_log}" || true)"
  [[ "${delete_count}" -eq 2 ]] || fail "postgres init success should delete old Job before apply and completed Job after success"
  pass "Postgres init succeeds from Job Complete without reading log sentinel"
}

test_postgres_init_wait_failure_keeps_job_and_collects_debug() {
  local cache="${TMP_DIR}/postgres-init-failure-cache"
  local env_dir="${TMP_DIR}/postgres-init-failure-env"
  local render_dir="${TMP_DIR}/postgres-init-failure-render"
  local kubectl_log="${TMP_DIR}/postgres-init-failure-kubectl.log"
  local out="${TMP_DIR}/postgres-init-failure.out"
  local delete_count
  local status=0

  mkdir -p "${cache}/bin" "${render_dir}"
  write_valid_env_pair "${env_dir}"
  write_live_kubectl_stub "${cache}/bin/kubectl"
  write_fake_artifact "${render_dir}/postgres-init-job.yaml" "kind: Job"

  set +e
  KUBECTL_LOG="${kubectl_log}" \
    KUBECTL_FAIL_POSTGRES_INIT_WAIT=true \
    bash -c 'set -euo pipefail; source "$1"; offline_install_init_postgres_databases "$2" "$3" "$4"' \
      _ \
      "${ROOT_DIR}/scripts/lib/offline_install.sh" \
      "${cache}" \
      "${env_dir}/substrate.env" \
      "${render_dir}" \
      >"${out}" 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || fail "postgres init wait failure test should fail"
  assert_contains "${out}" "Postgres init Job failed; refusing to continue"
  assert_contains "${kubectl_log}" "logs -l job-name=agentsmith-lite-postgres-init --all-containers --tail=-1"
  assert_contains "${kubectl_log}" "describe job agentsmith-lite-postgres-init"
  delete_count="$(grep -Fc "delete job agentsmith-lite-postgres-init" "${kubectl_log}" || true)"
  [[ "${delete_count}" -eq 1 ]] || fail "postgres init failure should not delete Job after failure"
  pass "Postgres init wait failure keeps Job and collects logs plus describe"
}

test_minio_bucket_init_failure_keeps_job_and_collects_debug() {
  local cache="${TMP_DIR}/bucket-init-failure-cache"
  local env_dir="${TMP_DIR}/bucket-init-failure-env"
  local render_dir="${TMP_DIR}/bucket-init-failure-render"
  local kubectl_log="${TMP_DIR}/bucket-init-failure-kubectl.log"
  local out="${TMP_DIR}/bucket-init-failure.out"
  local delete_count
  local status=0

  mkdir -p "${cache}/bin" "${render_dir}"
  write_valid_env_pair "${env_dir}"
  write_live_kubectl_stub "${cache}/bin/kubectl"
  write_fake_artifact "${render_dir}/minio-bucket-init-job.yaml" "kind: Job"

  set +e
  KUBECTL_LOG="${kubectl_log}" \
    KUBECTL_FAIL_MINIO_BUCKET_WAIT=true \
    bash -c 'set -euo pipefail; source "$1"; offline_install_init_minio_bucket "$2" "$3" "$4"' \
      _ \
      "${ROOT_DIR}/scripts/lib/offline_install.sh" \
      "${cache}" \
      "${env_dir}/substrate.env" \
      "${render_dir}" \
      >"${out}" 2>&1
  status=$?
  set -e

  [[ "${status}" -ne 0 ]] || fail "bucket init failure test should fail"
  assert_contains "${out}" "MinIO bucket init Job failed; refusing to continue"
  assert_contains "${kubectl_log}" "logs -l job-name=agentsmith-lite-minio-bucket-init --all-containers --tail=-1"
  assert_contains "${kubectl_log}" "describe job agentsmith-lite-minio-bucket-init"
  delete_count="$(grep -Fc "delete job agentsmith-lite-minio-bucket-init" "${kubectl_log}" || true)"
  [[ "${delete_count}" -eq 1 ]] || fail "bucket init failure should not delete Job after failure"
  pass "MinIO bucket init failure keeps Job and collects logs plus describe"
}

test_contract_cache_install_and_static_juicefs() {
  local cache="${TMP_DIR}/contract-cache"
  local output="${TMP_DIR}/install-out"
  local download_out="${TMP_DIR}/download-online.out"
  local install_out="${TMP_DIR}/install-online.out"
  local juicefs_out="${TMP_DIR}/juicefs.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${download_out}" 2>&1
  assert_contains "${cache}/manifest.yaml" "cacheMode: p0-contract"
  assert_contains "${cache}/manifest.yaml" "images/oci/keycloak.tar"
  assert_contains "${cache}/images/images.lock" "name: keycloak"
  assert_contains "${cache}/images/images.lock" "archive: images/oci/keycloak.tar"
  test -f "${cache}/images/oci/keycloak.tar" || fail "expected contract cache to include images/oci/keycloak.tar"

  "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${output}" \
    --dry-run \
    --force \
    >"${install_out}" 2>&1
  assert_contains "${install_out}" "dry-run: validated P0 static cache skeleton only"

  "${ROOT_DIR}/scripts/validate-env.sh" \
    --env "${output}/substrate.env" \
    --secrets "${output}/substrate.secrets.env" \
    >"${TMP_DIR}/install-validate-env.out" 2>&1
  "${ROOT_DIR}/scripts/validate-juicefs-contract.sh" \
    --env "${output}/substrate.env" \
    --secrets "${output}/substrate.secrets.env" \
    >"${juicefs_out}" 2>&1

  assert_contains "${output}/substrate.env" "AUTH_MODE=oidc"
  assert_contains "${output}/substrate.env" "KUBE_CONTEXT="
  assert_contains "${output}/substrate.env" "OIDC_ISSUER_URL=http://keycloak.agentsmith.localhost/realms/agentsmith"
  assert_contains "${output}/substrate.env" "OIDC_CLIENT_ID=agentsmith-lite"
  assert_contains "${output}/substrate.env" "OIDC_BACKCHANNEL_BASE_URL=http://keycloak.agentsmith.svc.cluster.local:8080/realms/agentsmith"
  assert_contains "${output}/substrate.secrets.env" "OIDC_BOOTSTRAP_USERNAME=agentsmith-local"
  assert_contains "${output}/substrate.secrets.env" "OIDC_BOOTSTRAP_PASSWORD="
  assert_not_contains "${output}/substrate.secrets.env" "OIDC_BOOTSTRAP_PASSWORD=$"
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_DB_USER=keycloak"
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_DB_PASSWORD="
  assert_not_contains "${output}/substrate.secrets.env" "KEYCLOAK_DB_PASSWORD=$"
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_DB_DATABASE=keycloak"
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_ADMIN_USERNAME=admin"
  assert_contains "${output}/substrate.secrets.env" "KEYCLOAK_ADMIN_PASSWORD="
  assert_not_contains "${output}/substrate.secrets.env" "KEYCLOAK_ADMIN_PASSWORD=$"
  assert_contains "${juicefs_out}" "JuiceFS CSI contract validated"
  pass "contract-only cache, install-online dry-run, env, and static JuiceFS contracts pass"
}

test_self_hosted_keycloak_render_from_p1_cache() {
  local artifacts="${TMP_DIR}/keycloak-render-artifacts"
  local lock="${TMP_DIR}/keycloak-render-artifacts.env"
  local cache="${TMP_DIR}/keycloak-render-cache"
  local output="${TMP_DIR}/keycloak-render-out"
  local out="${TMP_DIR}/keycloak-render-install.out"
  local bootstrap_job="${output}/rendered/offline-install/keycloak-bootstrap-job.yaml"
  local keycloak_secret="${output}/rendered/offline-install/keycloak-secret.yaml"
  local postgres_secret="${output}/rendered/offline-install/postgres-secret.yaml"

  write_fake_p1_artifact_lock "${artifacts}" "${lock}"
  "${ROOT_DIR}/scripts/download-online.sh" --artifacts "${lock}" --output "${cache}" --force >"${TMP_DIR}/keycloak-render-cache.out" 2>&1
  "${ROOT_DIR}/scripts/install-online.sh" \
    --cache "${cache}" \
    --config "${ROOT_DIR}/config/substrates.self-hosted.example.yaml" \
    --output "${output}" \
    --dry-run \
    --force \
    >"${out}" 2>&1

  assert_contains "${out}" "dry-run: validated p1-real cache contract; skipped cluster mutation"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "kind: Deployment"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "kind: Ingress"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "name: keycloak"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "host: keycloak.agentsmith.localhost"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "name: keycloak"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "number: 8080"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "containerPort: 9000"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "name: management"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "path: /health/ready"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "port: management"
  assert_contains "${output}/rendered/offline-install/keycloak.yaml" "KC_HEALTH_ENABLED"
  assert_contains "${bootstrap_job}" "name: agentsmith-lite-keycloak-bootstrap"
  assert_contains "${keycloak_secret}" "oidcBootstrapUsername:"
  assert_contains "${keycloak_secret}" "oidcBootstrapPassword:"
  assert_contains "${keycloak_secret}" "dbUsername: $(env_file_value_b64 "${output}/substrate.secrets.env" KEYCLOAK_DB_USER)"
  assert_contains "${keycloak_secret}" "dbPassword: $(env_file_value_b64 "${output}/substrate.secrets.env" KEYCLOAK_DB_PASSWORD)"
  assert_contains "${keycloak_secret}" "dbDatabase: $(env_file_value_b64 "${output}/substrate.secrets.env" KEYCLOAK_DB_DATABASE)"
  assert_contains "${keycloak_secret}" "adminUsername: $(env_file_value_b64 "${output}/substrate.secrets.env" KEYCLOAK_ADMIN_USERNAME)"
  assert_contains "${keycloak_secret}" "adminPassword: $(env_file_value_b64 "${output}/substrate.secrets.env" KEYCLOAK_ADMIN_PASSWORD)"
  assert_contains "${postgres_secret}" "keycloakUsername: $(env_file_value_b64 "${output}/substrate.secrets.env" KEYCLOAK_DB_USER)"
  assert_contains "${postgres_secret}" "keycloakPassword: $(env_file_value_b64 "${output}/substrate.secrets.env" KEYCLOAK_DB_PASSWORD)"
  assert_contains "${postgres_secret}" "keycloakDatabase: $(env_file_value_b64 "${output}/substrate.secrets.env" KEYCLOAK_DB_DATABASE)"
  assert_contains "${bootstrap_job}" "activeDeadlineSeconds: 900"
  assert_contains "${bootstrap_job}" "kcadm()"
  assert_contains "${bootstrap_job}" "/usr/bin/timeout 30"
  assert_contains "${bootstrap_job}" "command -v timeout"
  assert_contains "${bootstrap_job}" "OIDC_BOOTSTRAP_USERNAME"
  assert_contains "${bootstrap_job}" "emailVerified=true"
  assert_contains "${bootstrap_job}" 'bootstrap_email="bootstrap@agentsmith.localhost"'
  assert_contains "${bootstrap_job}" 'bootstrap_first_name="Agentsmith"'
  assert_contains "${bootstrap_job}" 'bootstrap_last_name="Local"'
  assert_contains "${bootstrap_job}" 'email=$bootstrap_email'
  assert_contains "${bootstrap_job}" 'firstName=$bootstrap_first_name'
  assert_contains "${bootstrap_job}" 'lastName=$bootstrap_last_name'
  assert_contains "${bootstrap_job}" "requiredActions=[]"
  assert_contains "${bootstrap_job}" "set-password"
  assert_contains "${bootstrap_job}" "--fields id"
  assert_contains "${bootstrap_job}" "--format csv"
  assert_contains "${bootstrap_job}" "--noquotes"
  assert_contains "${bootstrap_job}" "-q exact=true"
  assert_not_contains "${bootstrap_job}" "awk"
  assert_not_contains "${bootstrap_job}" "jq"
  assert_not_contains "${bootstrap_job}" "python"
  assert_contains "${bootstrap_job}" "keycloak realm client ready"
  assert_contains "${postgres_secret}" "keycloakDatabase:"
  assert_contains "${output}/rendered/offline-install/postgres-init-job.yaml" "KEYCLOAK_DB_USER"
  pass "self-hosted p1 dry-run renders Keycloak and Postgres bootstrap config"
}

test_existing_cloud_dry_run_does_not_render_keycloak() {
  local cache="${TMP_DIR}/existing-cloud-no-keycloak-cache"
  local output="${TMP_DIR}/existing-cloud-no-keycloak-out"
  local out="${TMP_DIR}/existing-cloud-no-keycloak-install.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/existing-cloud-no-keycloak-cache.out" 2>&1
  POSTGRES_APP_URL='postgresql://agentsmith:secret@postgres.example.com:5432/agentsmith_lite' \
    JUICEFS_META_URL='postgres://juicefs:secret@postgres.example.com:5432/juicefs_meta' \
    S3_ACCESS_KEY='existing-cloud-access-key' \
    S3_SECRET_KEY='existing-cloud-secret-key' \
    APP_SESSION_SECRET='existing-cloud-app-session-secret-value' \
    OIDC_ISSUER_URL='https://auth.agentsmith.example.com/realms/agentsmith' \
    OIDC_CLIENT_ID='agentsmith-lite' \
    OIDC_BACKCHANNEL_BASE_URL='http://keycloak.agentsmith.svc.cluster.local:8080/realms/agentsmith' \
    OIDC_CLIENT_SECRET='existing-cloud-oidc-secret' \
    "${ROOT_DIR}/scripts/install-online.sh" \
      --cache "${cache}" \
      --config "${ROOT_DIR}/config/substrates.existing-cloud.example.yaml" \
      --output "${output}" \
      --dry-run \
      --force \
      >"${out}" 2>&1

  test ! -e "${output}/rendered/offline-install/keycloak.yaml" \
    || fail "existing-cloud dry-run must not render self-hosted Keycloak"
  assert_contains "${out}" "dry-run: validated P0 static cache skeleton only"
  pass "existing-cloud dry-run skips self-hosted Keycloak render"
}

test_doctor_dry_run_status_lines() {
  local cache="${TMP_DIR}/doctor-cache"
  local env_dir="${TMP_DIR}/doctor-env"
  local out="${TMP_DIR}/doctor-dry-run.out"

  write_valid_env_pair "${env_dir}"
  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${TMP_DIR}/doctor-cache.out" 2>&1
  "${ROOT_DIR}/scripts/doctor.sh" \
    --env "${env_dir}/substrate.env" \
    --secrets "${env_dir}/substrate.secrets.env" \
    --offline-cache "${cache}" \
    --dry-run \
    >"${out}" 2>&1

  assert_contains "${out}" "env/secrets: passed - split substrate env contract is valid"
  assert_contains "${out}" "juicefs-csi: passed - dry-run static: rendered JuiceFS Secret, StorageClass, and PVC contract is valid"
  assert_contains "${out}" "offline-cache: passed - P0 static cache skeleton is valid"
  assert_contains "${out}" "doctor passed"
  pass "doctor dry-run prints status lines"
}

test_live_juicefs_contract_mismatch() {
  local env_dir="${TMP_DIR}/live-mismatch-env"
  local kubectl="${TMP_DIR}/live-mismatch-bin/kubectl"
  local kubectl_log="${TMP_DIR}/live-mismatch-kubectl.log"
  local out="${TMP_DIR}/live-mismatch.out"
  local status=0

  write_valid_env_pair "${env_dir}"
  write_live_kubectl_stub "${kubectl}"

  set +e
  export JUICEFS_FAKE_SC_PROVISIONER_SECRET_NAME="wrong-secret"
  run_live_doctor "${env_dir}" "${kubectl}" "${kubectl_log}" "${out}"
  status=$?
  unset JUICEFS_FAKE_SC_PROVISIONER_SECRET_NAME
  set -e

  [[ "${status}" -eq 1 ]] || fail "doctor live mismatch should exit 1, got ${status}"
  assert_contains "${out}" "juicefs-csi: failed - live JuiceFS StorageClass provisioner secret name does not match substrate contract"
  assert_contains "${out}" "doctor failed"
  assert_contains "${kubectl_log}" "jsonpath={.parameters.csi\\.storage\\.k8s\\.io/provisioner-secret-name}"
  pass "live JuiceFS StorageClass contract mismatch fails"
}

test_live_pvc_bound_rwx_success() {
  local env_dir="${TMP_DIR}/live-success-env"
  local kubectl="${TMP_DIR}/live-success-bin/kubectl"
  local kubectl_log="${TMP_DIR}/live-success-kubectl.log"
  local out="${TMP_DIR}/live-success.out"
  local status=0

  write_valid_env_pair "${env_dir}"
  write_live_kubectl_stub "${kubectl}"
  set +e
  run_live_doctor "${env_dir}" "${kubectl}" "${kubectl_log}" "${out}"
  status=$?
  set -e
  if [[ "${status}" -ne 0 ]]; then
    printf 'doctor live success output:\n' >&2
    sed -n '1,220p' "${out}" >&2
    fail "doctor live success should exit 0, got ${status}"
  fi

  assert_contains "${out}" "k8s: passed - namespace agentsmith is reachable"
  assert_contains "${out}" "postgres-app: passed - app database accepted a simple query"
  assert_contains "${out}" "s3: passed - live S3 read/write/delete probe passed"
  assert_contains "${out}" "juicefs-csi: passed - live JuiceFS PVC phase is Bound and StorageClass, Secret, and PVC contract matches"
  assert_contains "${out}" "rwx-check: passed - live two-Job ReadWriteMany write/read check passed against PVC agentsmith-lite-files"
  assert_contains "${out}" "doctor passed"
  assert_contains "${kubectl_log}" "jsonpath={.parameters.csi\\.storage\\.k8s\\.io/node-publish-secret-name}"
  pass "live PVC Bound and RWX write/read check success path passes"
}

test_env_secrets_contract
test_oidc_env_contract
test_oidc_env_contract_rejects_missing_required_values
test_builtin_admin_rejects_oidc_bootstrap_credentials
test_existing_cloud_oidc_reads_default_env_names
test_existing_cloud_rejects_postgresql_juicefs_meta_url
test_self_hosted_default_kube_context_is_empty
test_self_hosted_default_juicefs_bucket_is_http_bucket_url
test_self_hosted_default_juicefs_meta_url_uses_postgres_scheme
test_juicefs_bucket_contract_rejects_s3_prefix_url
test_juicefs_meta_url_contract_requires_postgres_scheme
test_json_schemas_match_juicefs_contract
test_self_hosted_force_reuses_existing_persistent_secrets
test_self_hosted_force_rejects_partial_or_invalid_output
test_self_hosted_skip_k3s_requires_readable_kubeconfig
test_self_hosted_skip_k3s_live_uses_existing_cluster_chain
test_minio_bucket_job_uses_mc_alias_and_retry
test_s3_probe_job_uses_mc_alias_and_object_lifecycle
test_minio_statefulset_has_health_probes
test_juicefs_format_job_surfaces_failure_logs_and_checks_storage
test_postgres_statefulset_has_pg_isready_readiness_probe
test_postgres_init_complete_does_not_require_log_sentinel
test_postgres_init_wait_failure_keeps_job_and_collects_debug
test_minio_bucket_init_failure_keeps_job_and_collects_debug
test_contract_cache_install_and_static_juicefs
test_self_hosted_keycloak_render_from_p1_cache
test_existing_cloud_dry_run_does_not_render_keycloak
test_doctor_dry_run_status_lines
test_live_juicefs_contract_mismatch
test_live_pvc_bound_rwx_success

printf '1..%d\n' "${pass_count}"
