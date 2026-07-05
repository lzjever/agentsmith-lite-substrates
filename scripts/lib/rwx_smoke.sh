#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

rwx_smoke_validate_name() {
  local label="$1"
  local value="$2"
  [[ "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "${label} must be a DNS label before running RWX smoke"
}

rwx_smoke_render_job() {
  local output="$1"
  local role="$2"
  local job_name="$3"
  local namespace="$4"
  local pvc_name="$5"
  local image_ref="$6"
  local run_id="$7"
  local payload="agentsmith-lite-rwx-smoke:${run_id}"

  case "${role}" in
    writer|reader) ;;
    *) die "invalid RWX smoke role: ${role}" ;;
  esac

  cat >"${output}" <<EOF_JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: agentsmith-lite-substrate-doctor
    agentsmith-lite/check: rwx-smoke
    agentsmith-lite/run-id: ${run_id}
    agentsmith-lite/role: ${role}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/managed-by: agentsmith-lite-substrate-doctor
        agentsmith-lite/check: rwx-smoke
        agentsmith-lite/run-id: ${run_id}
        agentsmith-lite/role: ${role}
    spec:
      restartPolicy: Never
      containers:
        - name: ${role}
          image: ${image_ref}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -ceu
            - |
EOF_JOB

  if [[ "${role}" == "writer" ]]; then
    cat >>"${output}" <<EOF_WRITER
              mount_dir="/mnt/rwx-smoke"
              payload_path="\${mount_dir}/payload-${run_id}"
              printf '%s\n' '${payload}' >"\${payload_path}"
              sync "\${payload_path}" 2>/dev/null || true
              printf 'agentsmith-lite-rwx-smoke writer wrote payload\n'
              sleep 10
EOF_WRITER
  else
    cat >>"${output}" <<EOF_READER
              mount_dir="/mnt/rwx-smoke"
              payload_path="\${mount_dir}/payload-${run_id}"
              i=0
              while [ "\${i}" -lt 30 ]; do
                if [ -f "\${payload_path}" ] && [ "\$(cat "\${payload_path}")" = '${payload}' ]; then
                  printf 'agentsmith-lite-rwx-smoke reader verified payload\n'
                  exit 0
                fi
                i=\$((i + 1))
                sleep 1
              done
              printf 'agentsmith-lite-rwx-smoke reader could not verify payload\n' >&2
              exit 1
EOF_READER
  fi

  cat >>"${output}" <<EOF_VOLUME
          volumeMounts:
            - name: rwx-volume
              mountPath: /mnt/rwx-smoke
      volumes:
        - name: rwx-volume
          persistentVolumeClaim:
            claimName: ${pvc_name}
EOF_VOLUME
}

rwx_smoke_cleanup() {
  local kubectl_bin="$1"
  local namespace="$2"
  local run_id="$3"
  shift 3
  local kubectl_args=("$@")

  "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" delete job -l "agentsmith-lite/run-id=${run_id}" --ignore-not-found=true >/dev/null 2>&1 || true
}

rwx_smoke_collect_logs() {
  local kubectl_bin="$1"
  local namespace="$2"
  local writer_job="$3"
  local reader_job="$4"
  shift 4
  local kubectl_args=("$@")
  local job

  for job in "${reader_job}" "${writer_job}"; do
    printf 'rwx smoke logs for %s:\n' "${job}" >&2
    "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" logs "job/${job}" --tail=100 >&2 || true
  done
}

rwx_smoke_run() {
  local namespace="$1"
  local pvc_name="$2"
  local image_ref="$3"
  local kubectl_bin="$4"
  shift 4
  local kubectl_args=("$@")

  rwx_smoke_validate_name "KUBE_NAMESPACE" "${namespace}"
  rwx_smoke_validate_name "JUICEFS_PVC_NAME" "${pvc_name}"
  require_digest_pinned_image_ref "RWX smoke image" "${image_ref}"
  [[ -x "${kubectl_bin}" || "${kubectl_bin}" == "kubectl" ]] || die "kubectl binary is not executable for RWX smoke"

  local run_id writer_job reader_job tmp_dir writer_manifest reader_manifest
  run_id="${RWX_SMOKE_RUN_ID:-$(date +%s)-${RANDOM}${RANDOM}}"
  run_id="${run_id:0:24}"
  writer_job="agentsmith-lite-rwx-smoke-writer-${run_id}"
  reader_job="agentsmith-lite-rwx-smoke-reader-${run_id}"
  tmp_dir="$(mktemp -d)"
  writer_manifest="${tmp_dir}/rwx-smoke-writer.yaml"
  reader_manifest="${tmp_dir}/rwx-smoke-reader.yaml"

  (
    set +e
    trap 'rwx_smoke_cleanup "${kubectl_bin}" "${namespace}" "${run_id}" "${kubectl_args[@]}"; rm -rf "${tmp_dir}"' EXIT

    local status=0
    local failure_step=""

    rwx_smoke_render_job "${writer_manifest}" "writer" "${writer_job}" "${namespace}" "${pvc_name}" "${image_ref}" "${run_id}" || {
      status=$?
      failure_step="render writer Job"
    }
    if [[ "${status}" -eq 0 ]]; then
      rwx_smoke_render_job "${reader_manifest}" "reader" "${reader_job}" "${namespace}" "${pvc_name}" "${image_ref}" "${run_id}" || {
        status=$?
        failure_step="render reader Job"
      }
    fi
    if [[ "${status}" -eq 0 ]]; then
      "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" apply -f "${writer_manifest}" || {
        status=$?
        failure_step="apply writer Job"
      }
    fi
    if [[ "${status}" -eq 0 ]]; then
      "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" wait --for=condition=Ready pod -l "agentsmith-lite/run-id=${run_id},agentsmith-lite/role=writer" --timeout=60s || {
        status=$?
        failure_step="wait for writer Pod readiness"
      }
    fi
    if [[ "${status}" -eq 0 ]]; then
      "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" apply -f "${reader_manifest}" || {
        status=$?
        failure_step="apply reader Job"
      }
    fi
    if [[ "${status}" -eq 0 ]]; then
      "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" wait --for=condition=complete "job/${reader_job}" --timeout=120s || {
        status=$?
        failure_step="wait for reader Job completion"
      }
    fi
    if [[ "${status}" -eq 0 ]]; then
      "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" wait --for=condition=complete "job/${writer_job}" --timeout=120s || {
        status=$?
        failure_step="wait for writer Job completion"
      }
    fi

    if [[ "${status}" -ne 0 ]]; then
      rwx_smoke_collect_logs "${kubectl_bin}" "${namespace}" "${writer_job}" "${reader_job}" "${kubectl_args[@]}"
      printf 'rwx smoke failed at %s\n' "${failure_step}" >&2
      exit "${status}"
    fi

    rwx_smoke_collect_logs "${kubectl_bin}" "${namespace}" "${writer_job}" "${reader_job}" "${kubectl_args[@]}"
    printf 'rwx smoke passed: writer=%s reader=%s run-id=%s\n' "${writer_job}" "${reader_job}" "${run_id}"
    exit 0
  )
}
