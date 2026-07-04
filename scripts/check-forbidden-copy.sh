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
trap 'rm -f "${tmp}"' EXIT

for pattern in "${patterns[@]}"; do
  if grep -RInF \
    --exclude-dir=.git \
    --exclude='check-forbidden-copy.sh' \
    --exclude='test.sh' \
    -- "${pattern}" "${ROOT_DIR}" >>"${tmp}"; then
    :
  fi
done

if [[ -s "${tmp}" ]]; then
  cat "${tmp}" >&2
  printf 'error: forbidden copied governance/reference surface found\n' >&2
  exit 1
fi

printf 'forbidden-copy guard passed\n'
