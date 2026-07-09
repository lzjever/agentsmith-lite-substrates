#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

s3_probe_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

s3_probe_validate_name() {
  local label="$1"
  local value="$2"
  [[ "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "${label} must be a DNS label before running S3 probe"
}

s3_probe_render_secret() {
  local output="$1"
  local secret_name="$2"
  local namespace="$3"
  local run_id="$4"
  local endpoint="$5"
  local region="$6"
  local bucket="$7"
  local force_path_style="$8"
  local access_key="$9"
  local secret_key="${10}"

  cat >"${output}" <<EOF_SECRET
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: agentsmith-lite-substrate-probe
    agentsmith-lite/check: s3-probe
    agentsmith-lite/run-id: ${run_id}
type: Opaque
data:
  S3_ENDPOINT: $(s3_probe_base64 "${endpoint}")
  S3_REGION: $(s3_probe_base64 "${region}")
  S3_BUCKET: $(s3_probe_base64 "${bucket}")
  S3_FORCE_PATH_STYLE: $(s3_probe_base64 "${force_path_style}")
  S3_ACCESS_KEY: $(s3_probe_base64 "${access_key}")
  S3_SECRET_KEY: $(s3_probe_base64 "${secret_key}")
EOF_SECRET
}

s3_probe_render_job() {
  local output="$1"
  local job_name="$2"
  local secret_name="$3"
  local namespace="$4"
  local image_ref="$5"
  local run_id="$6"

  cat >"${output}" <<EOF_JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: agentsmith-lite-substrate-probe
    agentsmith-lite/check: s3-probe
    agentsmith-lite/run-id: ${run_id}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/managed-by: agentsmith-lite-substrate-probe
        agentsmith-lite/check: s3-probe
        agentsmith-lite/run-id: ${run_id}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: s3-probe
          image: ${image_ref}
          imagePullPolicy: IfNotPresent
          env:
            - name: S3_ENDPOINT
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: S3_ENDPOINT
            - name: S3_REGION
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: S3_REGION
            - name: S3_BUCKET
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: S3_BUCKET
            - name: S3_FORCE_PATH_STYLE
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: S3_FORCE_PATH_STYLE
            - name: S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: S3_ACCESS_KEY
            - name: S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: S3_SECRET_KEY
            - name: S3_PROBE_RUN_ID
              value: ${run_id}
          command:
            - /bin/sh
            - -ceu
            - |
              set +x
              alias_name="agentsmith-lite-probe"
              object_key="agentsmith-lite-probe/s3-probe/\${S3_PROBE_RUN_ID}"
              object_uri="\${alias_name}/\${S3_BUCKET}/\${object_key}"
              payload="agentsmith-lite-s3-probe:\${S3_PROBE_RUN_ID}"
              MC_CONFIG_DIR="/tmp/agentsmith-lite-s3-probe-\${S3_PROBE_RUN_ID}"
              readback=""

              fail_probe() {
                printf 'agentsmith-lite-s3-probe failed: %s\n' "\$1" >&2
                exit 1
              }

              cleanup() {
                mc --config-dir "\${MC_CONFIG_DIR}" rm --quiet --force "\${object_uri}" >/dev/null 2>&1 || :
              }
              trap cleanup EXIT INT TERM

              case "\${S3_FORCE_PATH_STYLE}" in
                true) path_style="on" ;;
                false) path_style="off" ;;
                *) fail_probe "invalid S3_FORCE_PATH_STYLE" ;;
              esac

              export AWS_REGION="\${S3_REGION}"
              mc --config-dir "\${MC_CONFIG_DIR}" alias set "\${alias_name}" "\${S3_ENDPOINT}" "\${S3_ACCESS_KEY}" "\${S3_SECRET_KEY}" --api S3v4 --path "\${path_style}" >/dev/null 2>&1 \
                || fail_probe "configure client"

              printf '%s' "\${payload}" | mc --config-dir "\${MC_CONFIG_DIR}" pipe "\${object_uri}" >/dev/null 2>&1 \
                || fail_probe "write object"
              readback="\$(mc --config-dir "\${MC_CONFIG_DIR}" cat "\${object_uri}" 2>/dev/null)" \
                || fail_probe "read object"
              [ "\${readback}" = "\${payload}" ] \
                || fail_probe "verify object"
              mc --config-dir "\${MC_CONFIG_DIR}" rm --quiet --force "\${object_uri}" >/dev/null 2>&1 \
                || fail_probe "delete object"
              if mc --config-dir "\${MC_CONFIG_DIR}" stat "\${object_uri}" >/dev/null 2>&1; then
                fail_probe "confirm delete"
              fi
              printf 'agentsmith-lite-s3-probe passed\n'
EOF_JOB
}

s3_probe_cleanup() {
  local kubectl_bin="$1"
  local namespace="$2"
  local run_id="$3"
  shift 3
  local kubectl_args=("$@")
  local selector="agentsmith-lite/run-id=${run_id},agentsmith-lite/check=s3-probe"

  "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" delete job -l "${selector}" --ignore-not-found=true >/dev/null 2>&1 || true
  "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" delete secret -l "${selector}" --ignore-not-found=true >/dev/null 2>&1 || true
}

s3_probe_collect_logs() {
  local kubectl_bin="$1"
  local namespace="$2"
  local job_name="$3"
  shift 3
  local kubectl_args=("$@")

  printf 's3 probe logs for %s:\n' "${job_name}" >&2
  "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" logs "job/${job_name}" --tail=100 >&2 || true
}

s3_probe_run() {
  local namespace="$1"
  local image_ref="$2"
  local endpoint="$3"
  local region="$4"
  local bucket="$5"
  local force_path_style="$6"
  local access_key="$7"
  local secret_key="$8"
  local kubectl_bin="$9"
  shift 9
  local kubectl_args=("$@")

  s3_probe_validate_name "KUBE_NAMESPACE" "${namespace}"
  require_digest_pinned_image_ref "S3 probe image" "${image_ref}"
  [[ -x "${kubectl_bin}" || "${kubectl_bin}" == "kubectl" ]] || die "kubectl binary is not executable for S3 probe"

  local run_id job_name secret_name tmp_dir secret_manifest job_manifest
  run_id="${S3_PROBE_RUN_ID:-$(date +%s)-${RANDOM}${RANDOM}}"
  run_id="${run_id:0:24}"
  job_name="agentsmith-lite-s3-probe-${run_id}"
  secret_name="agentsmith-lite-s3-probe-${run_id}"
  tmp_dir="$(mktemp -d)"
  secret_manifest="${tmp_dir}/s3-probe-secret.yaml"
  job_manifest="${tmp_dir}/s3-probe-job.yaml"

  (
    set +e
    trap 's3_probe_cleanup "${kubectl_bin}" "${namespace}" "${run_id}" "${kubectl_args[@]}"; rm -rf "${tmp_dir}"' EXIT

    local status=0
    local failure_step=""

    umask 077
    s3_probe_render_secret "${secret_manifest}" "${secret_name}" "${namespace}" "${run_id}" "${endpoint}" "${region}" "${bucket}" "${force_path_style}" "${access_key}" "${secret_key}" || {
      status=$?
      failure_step="render Secret"
    }
    if [[ "${status}" -eq 0 ]]; then
      s3_probe_render_job "${job_manifest}" "${job_name}" "${secret_name}" "${namespace}" "${image_ref}" "${run_id}" || {
        status=$?
        failure_step="render Job"
      }
    fi
    chmod 0600 "${secret_manifest}" "${job_manifest}" 2>/dev/null || true

    if [[ "${status}" -eq 0 ]]; then
      "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" apply -f "${secret_manifest}" >/dev/null 2>&1 || {
        status=$?
        failure_step="apply Secret"
      }
    fi
    if [[ "${status}" -eq 0 ]]; then
      "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" apply -f "${job_manifest}" >/dev/null 2>&1 || {
        status=$?
        failure_step="apply Job"
      }
    fi
    if [[ "${status}" -eq 0 ]]; then
      "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" wait --for=condition=complete "job/${job_name}" --timeout=120s || {
        status=$?
        failure_step="wait for S3 probe Job completion"
      }
    fi

    if [[ "${status}" -ne 0 ]]; then
      case "${failure_step}" in
        "apply Secret"|"apply Job")
          ;;
        *)
          s3_probe_collect_logs "${kubectl_bin}" "${namespace}" "${job_name}" "${kubectl_args[@]}"
          ;;
      esac
      printf 's3 probe failed at %s\n' "${failure_step}" >&2
      exit "${status}"
    fi

    s3_probe_collect_logs "${kubectl_bin}" "${namespace}" "${job_name}" "${kubectl_args[@]}"
    printf 's3 probe passed: job=%s run-id=%s\n' "${job_name}" "${run_id}"
    exit 0
  )
}
