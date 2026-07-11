#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

make_binary() {
  local name="$1"
  local body="$2"
  mkdir -p "${tmp_dir}/bin"
  printf '%s\n' '#!/bin/bash' "${body}" >"${tmp_dir}/bin/${name}"
  chmod +x "${tmp_dir}/bin/${name}"
}

run_firewall() {
  PATH="${tmp_dir}/bin:/usr/bin:/bin" \
    K3S_HOST_FIREWALL_WRAPPER_DIR="${tmp_dir}/wrappers" \
    K3S_HOST_FIREWALL_DROPIN_FILE="${tmp_dir}/k3s.service.d/10-agentsmith-lite-legacy-xtables.conf" \
    SYSTEMCTL_LOG="${tmp_dir}/systemctl.log" \
    /bin/bash -ec "source '${ROOT_DIR}/scripts/lib/common.sh'; source '${ROOT_DIR}/scripts/lib/k3s_host_firewall.sh'; $*"
}

make_binary iptables 'if [[ "$1" == "--version" ]]; then echo "iptables v1.8.9 (nf_tables)"; fi'
make_binary iptables-legacy 'if [[ "$1" == "-S" ]]; then echo "-P FORWARD DROP"; fi'
make_binary iptables-save-legacy ':'
make_binary iptables-restore-legacy ':'
make_binary ip6tables-legacy ':'
make_binary ip6tables-save-legacy ':'
make_binary ip6tables-restore-legacy ':'
make_binary systemctl 'printf "%s\\n" "$*" >>"${SYSTEMCTL_LOG}"'

[[ "$(run_firewall 'k3s_host_firewall_needs_legacy_xtables; echo yes')" == "yes" ]] \
  || { printf 'expected nft plus legacy FORWARD DROP detection\n' >&2; exit 1; }

rendered="$(run_firewall 'k3s_host_firewall_render_dropin')"
expected=$'# Managed by agentsmith-lite-substrates: k3s legacy xtables\n[Service]\nEnvironment="PATH='"${tmp_dir}"'/wrappers:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
[[ "${rendered}" == "${expected}" ]] \
  || { printf 'expected managed legacy xtables drop-in content\n' >&2; exit 1; }

dropin="${tmp_dir}/k3s.service.d/10-agentsmith-lite-legacy-xtables.conf"
run_firewall 'k3s_host_firewall_install_legacy_xtables'
run_firewall 'k3s_host_firewall_dropin_is_current' \
  || { printf 'expected exact managed drop-in to be current\n' >&2; exit 1; }
[[ "$(cat "${tmp_dir}/systemctl.log")" == $'daemon-reload\ntry-restart k3s.service' ]] \
  || { printf 'expected initial drop-in install to reload and restart k3s\n' >&2; exit 1; }

run_firewall 'k3s_host_firewall_install_legacy_xtables'
[[ "$(wc -l <"${tmp_dir}/systemctl.log")" == "2" ]] \
  || { printf 'expected unchanged drop-in to avoid restarting k3s\n' >&2; exit 1; }

printf '%s\n' 'Environment="EXTRA=value"' >>"${dropin}"
if run_firewall 'k3s_host_firewall_dropin_is_current'; then
  printf 'expected user-modified drop-in to require update\n' >&2
  exit 1
fi

printf 'k3s legacy xtables behavior passed\n'
