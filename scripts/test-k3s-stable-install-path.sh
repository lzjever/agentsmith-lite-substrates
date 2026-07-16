#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/offline_install.sh
source "${ROOT_DIR}/scripts/lib/offline_install.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
cache_dir="${tmp_dir}/offline-cache"
stable_bin_dir="${tmp_dir}/installed/bin"
service_file="${tmp_dir}/k3s.service"
mkdir -p "${cache_dir}/bin" "${cache_dir}/scripts" "${cache_dir}/images/k3s"

cat >"${cache_dir}/bin/k3s" <<'EOF_K3S'
#!/usr/bin/env bash
printf 'cached k3s\n'
EOF_K3S
chmod +x "${cache_dir}/bin/k3s"
printf 'airgap image\n' >"${cache_dir}/images/k3s/k3s-airgap-images-amd64.tar.zst"

cat >"${cache_dir}/scripts/install-k3s.sh" <<'EOF_INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
[[ "${INSTALL_K3S_BIN_DIR_READ_ONLY}" == "true" ]]
[[ -x "${INSTALL_K3S_BIN_DIR}/k3s" ]]
printf '[Service]\nExecStart=%s/k3s server\n' "${INSTALL_K3S_BIN_DIR}" >"${K3S_TEST_SERVICE_FILE}"
EOF_INSTALLER
chmod +x "${cache_dir}/scripts/install-k3s.sh"

cat >"${tmp_dir}/substrate.env" <<EOF_ENV
KUBECONFIG_PATH=${tmp_dir}/kubeconfig
EOF_ENV

k3s_host_firewall_prepare() { :; }
K3S_STABLE_BIN_DIR="${stable_bin_dir}" \
K3S_AIRGAP_DIR="${tmp_dir}/airgap" \
K3S_TEST_SERVICE_FILE="${service_file}" \
  offline_install_run_k3s_installer "${cache_dir}" "${tmp_dir}/substrate.env" "${tmp_dir}/out"

rm -rf "${cache_dir}"
[[ -x "${stable_bin_dir}/k3s" ]] \
  || { printf 'expected cached k3s binary to be installed at a stable path\n' >&2; exit 1; }
grep -Fx "ExecStart=${stable_bin_dir}/k3s server" "${service_file}" >/dev/null \
  || { printf 'expected k3s service to use the stable installed binary\n' >&2; exit 1; }
! grep -Fq 'offline-cache' "${service_file}" \
  || { printf 'k3s service must not depend on the offline cache path\n' >&2; exit 1; }

printf 'k3s stable install path passed\n'
