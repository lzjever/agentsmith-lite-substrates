#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/offline_install.sh
source "${ROOT_DIR}/scripts/lib/offline_install.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

cache_dir="${tmp_dir}/cache"
env_file="${tmp_dir}/substrate.env"
call_file="${tmp_dir}/rwx-call.tsv"

mkdir -p "${cache_dir}/bin" "${cache_dir}/images"
cat >"${cache_dir}/images/images.lock" <<'EOF_LOCK'
schemaVersion: agentsmith-lite.substrate.images/v1
images:
  - name: rwx-check
    image: registry.local/agentsmith-lite/rwx-check:dev@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    archive: images/oci/rwx-check.tar
    sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF_LOCK

cat >"${cache_dir}/bin/kubectl" <<'EOF_KUBECTL'
#!/usr/bin/env bash
printf 'kubectl stub should not be executed by this contract test\n' >&2
exit 64
EOF_KUBECTL
chmod +x "${cache_dir}/bin/kubectl"

cat >"${env_file}" <<EOF_ENV
KUBE_NAMESPACE=agentsmith
JUICEFS_PVC_NAME=agentsmith-lite-files
KUBECONFIG_PATH=${tmp_dir}/kubeconfig
KUBE_CONTEXT=agentsmith-local
EOF_ENV
touch "${tmp_dir}/kubeconfig"

rwx_write_read_check_run() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${*:5}" >"${call_file}"
}

offline_install_check_juicefs_rwx_write_read "${cache_dir}" "${env_file}"

expected_image="registry.local/agentsmith-lite/rwx-check:dev@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expected_kubectl="${cache_dir}/bin/kubectl"
expected_line=$'agentsmith\tagentsmith-lite-files\t'"${expected_image}"$'\t'"${expected_kubectl}"$'\t--kubeconfig '"${tmp_dir}/kubeconfig"$' --context agentsmith-local'
actual_line="$(cat "${call_file}")"
[[ "${actual_line}" == "${expected_line}" ]] \
  || die "RWX write/read install helper did not pass expected env/cache/lock values"

info "JuiceFS RWX write/read install contract validated"
