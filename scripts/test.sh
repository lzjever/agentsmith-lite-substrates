#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

POSTGRES_PROBE_IMAGE="docker.io/library/postgres:16@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
S3_PROBE_IMAGE="quay.io/minio/mc:RELEASE.2024-01-01T00-00-00Z@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
RWX_CHECK_IMAGE="docker.io/library/busybox:1.36.1@sha256:3333333333333333333333333333333333333333333333333333333333333333"

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
APP_SESSION_SECRET=app-session-secret-value-0123456789abcdef
S3_ACCESS_KEY=minio-access-key
S3_SECRET_KEY=minio-secret-value
JUICEFS_META_URL=postgresql://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta
BUILTIN_ADMIN_INITIAL_PASSWORD=admin-secret-value
OIDC_CLIENT_SECRET=
EOF_SECRETS
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
    juicefs_b64 "${JUICEFS_FAKE_SECRET_METAURL:-postgresql://juicefs:juicefs-secret-value@postgres.agentsmith.svc.cluster.local:5432/juicefs_meta}"
    ;;
  *"-n agentsmith get secret agentsmith-lite-juicefs -o jsonpath="*"storage"*)
    juicefs_b64 "${JUICEFS_FAKE_SECRET_STORAGE:-s3}"
    ;;
  *"-n agentsmith get secret agentsmith-lite-juicefs -o jsonpath="*"bucket"*)
    juicefs_b64 "${JUICEFS_FAKE_SECRET_BUCKET:-s3://agentsmith-lite-files/agentsmith-lite/}"
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

test_contract_cache_install_and_static_juicefs() {
  local cache="${TMP_DIR}/contract-cache"
  local output="${TMP_DIR}/install-out"
  local download_out="${TMP_DIR}/download-online.out"
  local install_out="${TMP_DIR}/install-online.out"
  local juicefs_out="${TMP_DIR}/juicefs.out"

  "${ROOT_DIR}/scripts/download-online.sh" --contract-only --output "${cache}" --force >"${download_out}" 2>&1
  assert_contains "${cache}/manifest.yaml" "cacheMode: p0-contract"

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

  assert_contains "${juicefs_out}" "JuiceFS CSI contract validated"
  pass "contract-only cache, install-online dry-run, env, and static JuiceFS contracts pass"
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
test_contract_cache_install_and_static_juicefs
test_doctor_dry_run_status_lines
test_live_juicefs_contract_mismatch
test_live_pvc_bound_rwx_success

printf '1..%d\n' "${pass_count}"
