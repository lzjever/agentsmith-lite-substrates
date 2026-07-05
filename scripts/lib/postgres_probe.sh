#!/usr/bin/env bash

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_LIB_DIR}/common.sh"

postgres_probe_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

postgres_probe_validate_name() {
  local label="$1"
  local value="$2"
  [[ "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "${label} must be a DNS label before running Postgres probe"
}

postgres_probe_render_secret() {
  local output="$1"
  local secret_name="$2"
  local namespace="$3"
  local run_id="$4"
  local probe_label="$5"
  local host="$6"
  local port="$7"
  local user="$8"
  local password="$9"
  local database="${10}"

  cat >"${output}" <<EOF_SECRET
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: agentsmith-lite-substrate-doctor
    agentsmith-lite/check: postgres-probe
    agentsmith-lite/postgres-check: ${probe_label}
    agentsmith-lite/run-id: ${run_id}
type: Opaque
data:
  PGHOST: $(postgres_probe_base64 "${host}")
  PGPORT: $(postgres_probe_base64 "${port}")
  PGUSER: $(postgres_probe_base64 "${user}")
  PGPASSWORD: $(postgres_probe_base64 "${password}")
  PGDATABASE: $(postgres_probe_base64 "${database}")
EOF_SECRET
}

postgres_probe_render_job() {
  local output="$1"
  local job_name="$2"
  local secret_name="$3"
  local namespace="$4"
  local image_ref="$5"
  local run_id="$6"
  local probe_label="$7"

  cat >"${output}" <<EOF_JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: agentsmith-lite-substrate-doctor
    agentsmith-lite/check: postgres-probe
    agentsmith-lite/postgres-check: ${probe_label}
    agentsmith-lite/run-id: ${run_id}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/managed-by: agentsmith-lite-substrate-doctor
        agentsmith-lite/check: postgres-probe
        agentsmith-lite/postgres-check: ${probe_label}
        agentsmith-lite/run-id: ${run_id}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: postgres-probe
          image: ${image_ref}
          imagePullPolicy: IfNotPresent
          env:
            - name: PGHOST
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: PGHOST
            - name: PGPORT
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: PGPORT
            - name: PGUSER
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: PGUSER
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: PGPASSWORD
            - name: PGDATABASE
              valueFrom:
                secretKeyRef:
                  name: ${secret_name}
                  key: PGDATABASE
            - name: PGCONNECT_TIMEOUT
              value: "10"
          command:
            - /bin/sh
            - -ceu
            - |
              set +x

              fail_probe() {
                printf 'agentsmith-lite-postgres-probe failed: %s\n' "\$1" >&2
                exit 1
              }

              : "\${PGHOST:?}"
              : "\${PGPORT:?}"
              : "\${PGUSER:?}"
              : "\${PGPASSWORD:?}"
              : "\${PGDATABASE:?}"
              : "\${PGCONNECT_TIMEOUT:?}"

              result="\$(psql -v ON_ERROR_STOP=1 -Atc 'select 1' 2>/dev/null)" \
                || fail_probe "select 1"
              [ "\${result}" = "1" ] || fail_probe "unexpected result"
              printf 'agentsmith-lite-postgres-probe passed\n'
EOF_JOB
}

postgres_probe_cleanup() {
  local kubectl_bin="$1"
  local namespace="$2"
  local run_id="$3"
  shift 3
  local kubectl_args=("$@")
  local selector="agentsmith-lite/run-id=${run_id},agentsmith-lite/check=postgres-probe"

  "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" delete job -l "${selector}" --ignore-not-found=true >/dev/null 2>&1 || true
  "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" delete secret -l "${selector}" --ignore-not-found=true >/dev/null 2>&1 || true
}

postgres_probe_collect_logs() {
  local kubectl_bin="$1"
  local namespace="$2"
  local job_name="$3"
  shift 3
  local kubectl_args=("$@")

  printf 'postgres probe logs for %s:\n' "${job_name}" >&2
  "${kubectl_bin}" "${kubectl_args[@]}" -n "${namespace}" logs "job/${job_name}" --tail=100 >&2 || true
}

postgres_probe_run() {
  local namespace="$1"
  local probe_label="$2"
  local image_ref="$3"
  local host="$4"
  local port="$5"
  local user="$6"
  local password="$7"
  local database="$8"
  local kubectl_bin="$9"
  shift 9
  local kubectl_args=("$@")

  postgres_probe_validate_name "KUBE_NAMESPACE" "${namespace}"
  postgres_probe_validate_name "Postgres probe label" "${probe_label}"
  require_digest_pinned_image_ref "Postgres probe image" "${image_ref}"
  [[ -x "${kubectl_bin}" || "${kubectl_bin}" == "kubectl" ]] || die "kubectl binary is not executable for Postgres probe"

  local run_id job_name secret_name tmp_dir secret_manifest job_manifest
  run_id="${POSTGRES_PROBE_RUN_ID:-$(date +%s)-${RANDOM}${RANDOM}}"
  run_id="${run_id:0:24}"
  job_name="asl-pg-probe-${probe_label}-${run_id}"
  secret_name="asl-pg-probe-${probe_label}-${run_id}"
  tmp_dir="$(mktemp -d)"
  secret_manifest="${tmp_dir}/postgres-probe-secret.yaml"
  job_manifest="${tmp_dir}/postgres-probe-job.yaml"

  (
    set +e
    trap 'postgres_probe_cleanup "${kubectl_bin}" "${namespace}" "${run_id}" "${kubectl_args[@]}"; rm -rf "${tmp_dir}"' EXIT

    local status=0
    local failure_step=""

    umask 077
    postgres_probe_render_secret "${secret_manifest}" "${secret_name}" "${namespace}" "${run_id}" "${probe_label}" "${host}" "${port}" "${user}" "${password}" "${database}" || {
      status=$?
      failure_step="render Secret"
    }
    if [[ "${status}" -eq 0 ]]; then
      postgres_probe_render_job "${job_manifest}" "${job_name}" "${secret_name}" "${namespace}" "${image_ref}" "${run_id}" "${probe_label}" || {
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
        failure_step="wait for Postgres probe Job completion"
      }
    fi

    if [[ "${status}" -ne 0 ]]; then
      case "${failure_step}" in
        "apply Secret"|"apply Job")
          ;;
        *)
          postgres_probe_collect_logs "${kubectl_bin}" "${namespace}" "${job_name}" "${kubectl_args[@]}"
          ;;
      esac
      printf 'postgres probe failed at %s\n' "${failure_step}" >&2
      exit "${status}"
    fi

    postgres_probe_collect_logs "${kubectl_bin}" "${namespace}" "${job_name}" "${kubectl_args[@]}"
    printf 'postgres probe passed: job=%s run-id=%s\n' "${job_name}" "${run_id}"
    exit 0
  )
}
