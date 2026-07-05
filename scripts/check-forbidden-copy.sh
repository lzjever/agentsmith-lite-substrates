#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

patterns=(
  '.reference/'
  'reference-tools'
  'reference-deploy-shared'
  'release evidence'
  'release-evidence'
  'GA report'
  'rehearsal matrix'
  'product:ready'
  'gate:'
  'LLMUP'
  'JVS'
  'AFSCP'
  'ASBCP'
)

tmp="$(mktemp)"
app_tmp="$(mktemp)"
trap 'rm -f "${tmp}" "${app_tmp}"' EXIT

for pattern in "${patterns[@]}"; do
  if grep -RInF \
    --exclude-dir=.git \
    --exclude='check-forbidden-copy.sh' \
    --exclude='test.sh' \
    -- "${pattern}" "${ROOT_DIR}" >>"${tmp}"; then
    :
  fi
done

app_owned_patterns=(
  'agentsmith-lite-api'
  'agentsmith-lite-web'
  'agentsmith-lite-app'
  'agentsmith-lite/app'
  'botified-runner'
)

for pattern in "${app_owned_patterns[@]}"; do
  for scan_dir in "${ROOT_DIR}/manifests" "${ROOT_DIR}/scripts"; do
    [[ -d "${scan_dir}" ]] || continue
    if grep -RInF \
      --exclude-dir=.git \
      --exclude='check-forbidden-copy.sh' \
      --exclude='test.sh' \
      --exclude='common.sh' \
      -- "${pattern}" "${scan_dir}" >>"${app_tmp}"; then
      :
    fi
  done
done

if [[ -s "${tmp}" ]]; then
  cat "${tmp}" >&2
  printf 'error: forbidden copied governance/reference surface found\n' >&2
  exit 1
fi

if [[ -s "${app_tmp}" ]]; then
  cat "${app_tmp}" >&2
  printf 'error: app-owned service/image references found in substrate manifests/scripts\n' >&2
  exit 1
fi

printf 'forbidden-copy guard passed\n'
