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

reset_fake_binaries() {
  rm -rf "${tmp_dir}/bin"
  mkdir -p "${tmp_dir}/bin"
  make_binary iptables 'if [[ "$1" == "--version" ]]; then echo "iptables v1.8.9 (nf_tables)"; fi'
  make_binary iptables-legacy 'case "$1" in --version) echo "iptables v1.8.9 (legacy)" ;; -S) echo "-P FORWARD DROP" ;; esac'
  make_binary ip6tables-legacy ':'
}

run_legacy_tool() {
  local tool="$1"
  PATH="${tmp_dir}/bin" /bin/bash -ec "source '${ROOT_DIR}/scripts/lib/common.sh'; source '${ROOT_DIR}/scripts/lib/k3s_host_firewall.sh'; k3s_host_firewall_legacy_tool '${tool}'"
}

reset_fake_binaries
make_binary iptables-save-legacy ':'
make_binary iptables-restore-legacy ':'
make_binary ip6tables-save-legacy ':'
make_binary ip6tables-restore-legacy ':'
[[ "$(run_legacy_tool iptables-save)" == "${tmp_dir}/bin/iptables-save-legacy" ]] || { printf 'expected Debian legacy save tool\n' >&2; exit 1; }
[[ "$(run_legacy_tool ip6tables-restore)" == "${tmp_dir}/bin/ip6tables-restore-legacy" ]] || { printf 'expected Debian IPv6 legacy restore tool\n' >&2; exit 1; }

reset_fake_binaries
make_binary iptables-legacy-save ':'
make_binary iptables-legacy-restore ':'
make_binary ip6tables-legacy-save ':'
make_binary ip6tables-legacy-restore ':'
[[ "$(run_legacy_tool iptables-save)" == "${tmp_dir}/bin/iptables-legacy-save" ]] || { printf 'expected Red Hat legacy save tool\n' >&2; exit 1; }
[[ "$(run_legacy_tool ip6tables-restore)" == "${tmp_dir}/bin/ip6tables-legacy-restore" ]] || { printf 'expected Red Hat IPv6 legacy restore tool\n' >&2; exit 1; }

# shellcheck source=lib/offline_install.sh
source "${ROOT_DIR}/scripts/lib/offline_install.sh"
kubectl_log="${tmp_dir}/kubectl.log"
manifest_copy="${tmp_dir}/coredns-pod.yaml"
cache_relative_path() { printf '%s/images/images.lock\n' "$1"; }
images_lock_image_ref() { printf '%s\n' 'docker.io/library/busybox:1.36.1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; }
offline_install_kubectl() {
  printf '%s\n' "$*" >>"${kubectl_log}"
  if [[ "$*" == *'apply -f '* ]]; then
    cp "${@: -1}" "${manifest_copy}"
  fi
}
offline_install_run_coredns_service_lookup "${tmp_dir}/cache" "${tmp_dir}/substrate.env"
grep -Fqx '    app.kubernetes.io/managed-by: agentsmith-lite-substrate-probe' "${manifest_copy}" >/dev/null \
  || { printf 'expected owned CoreDNS probe label\n' >&2; exit 1; }
grep -Fqx '  activeDeadlineSeconds: 120' "${manifest_copy}" >/dev/null \
  || { printf 'expected bounded CoreDNS probe deadline\n' >&2; exit 1; }
grep -Fq -- '--request-timeout=20s apply -f ' "${kubectl_log}" \
  || { printf 'expected bounded CoreDNS probe apply\n' >&2; exit 1; }
grep -Fq -- '--request-timeout=20s wait --for=condition=Ready pod/agentsmith-lite-coredns-lookup --timeout=90s' "${kubectl_log}" \
  || { printf 'expected bounded CoreDNS probe wait\n' >&2; exit 1; }
grep -Fq -- '--request-timeout=20s exec agentsmith-lite-coredns-lookup -- nslookup kubernetes.default.svc.cluster.local' "${kubectl_log}" \
  || { printf 'expected bounded CoreDNS lookup exec\n' >&2; exit 1; }
grep -Fq -- '--request-timeout=20s delete pod -l app.kubernetes.io/managed-by=agentsmith-lite-substrate-probe,agentsmith-lite/check=coredns-service-lookup --field-selector metadata.name=agentsmith-lite-coredns-lookup --ignore-not-found=true --wait=false' "${kubectl_log}" \
  || { printf 'expected owned CoreDNS probe cleanup selector\n' >&2; exit 1; }

printf 'k3s host firewall contract passed\n'
