#!/usr/bin/env bash

readonly K3S_HOST_FIREWALL_WRAPPER_DIR="/usr/local/lib/agentsmith-lite/k3s-xtables"
readonly K3S_HOST_FIREWALL_DROPIN_FILE="/etc/systemd/system/k3s.service.d/10-agentsmith-lite-legacy-xtables.conf"
readonly K3S_HOST_FIREWALL_DROPIN_MARKER="# Managed by agentsmith-lite-substrates: k3s legacy xtables"

k3s_host_firewall_legacy_tool_candidates() {
  local tool="$1"
  case "${tool}" in
    iptables|ip6tables) printf '%s\n' "${tool}-legacy" ;;
    iptables-save|ip6tables-save) printf '%s\n' "${tool%-save}-legacy-save" "${tool}-legacy" ;;
    iptables-restore|ip6tables-restore) printf '%s\n' "${tool%-restore}-legacy-restore" "${tool}-legacy" ;;
    *) return 1 ;;
  esac
}

k3s_host_firewall_legacy_tool() {
  local tool candidate
  tool="$1"
  while IFS= read -r candidate; do
    command -v "${candidate}" >/dev/null 2>&1 && { command -v "${candidate}"; return 0; }
  done < <(k3s_host_firewall_legacy_tool_candidates "${tool}")
  return 1
}

k3s_host_firewall_wrapper_target_is_owned() {
  local tool="$1"
  local target="$2"
  local candidate expected
  while IFS= read -r candidate; do
    expected="$(command -v "${candidate}" 2>/dev/null || true)"
    [[ -n "${expected}" && "${target}" == "${expected}" ]] && return 0
  done < <(k3s_host_firewall_legacy_tool_candidates "${tool}")
  return 1
}

k3s_host_firewall_restart_k3s() {
  systemctl daemon-reload
  systemctl try-restart k3s.service
}

k3s_host_firewall_remove_legacy_xtables() {
  local tool link target changed=false
  for tool in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
    link="${K3S_HOST_FIREWALL_WRAPPER_DIR}/${tool}"
    target="$(readlink "${link}" 2>/dev/null || true)"
    if [[ -n "${target}" ]] && k3s_host_firewall_wrapper_target_is_owned "${tool}" "${target}"; then
      rm -f -- "${link}"
      changed=true
    fi
  done
  rmdir "${K3S_HOST_FIREWALL_WRAPPER_DIR}" 2>/dev/null || true
  if grep -Fqx "${K3S_HOST_FIREWALL_DROPIN_MARKER}" "${K3S_HOST_FIREWALL_DROPIN_FILE}" 2>/dev/null; then
    rm -f -- "${K3S_HOST_FIREWALL_DROPIN_FILE}"
    changed=true
  fi
  if [[ "${changed}" == "true" ]]; then
    k3s_host_firewall_restart_k3s
  fi
}

k3s_host_firewall_legacy_forward_drops() {
  command -v iptables-legacy >/dev/null 2>&1 || return 1
  iptables-legacy -S FORWARD 2>/dev/null | grep -Fx -- '-P FORWARD DROP' >/dev/null
}

k3s_host_firewall_require_legacy_xtables() {
  local tool
  for tool in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
    k3s_host_firewall_legacy_tool "${tool}" >/dev/null \
      || die "mixed nft/legacy iptables host requires legacy xtables tools; missing legacy ${tool} binary"
  done
}

k3s_host_firewall_install_legacy_xtables() {
  local tool legacy_tool
  k3s_host_firewall_require_legacy_xtables
  mkdir -p "${K3S_HOST_FIREWALL_WRAPPER_DIR}" "$(dirname "${K3S_HOST_FIREWALL_DROPIN_FILE}")"
  for tool in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
    legacy_tool="$(k3s_host_firewall_legacy_tool "${tool}")"
    ln -sfn "${legacy_tool}" "${K3S_HOST_FIREWALL_WRAPPER_DIR}/${tool}"
  done
  printf '%s\n[Service]\nEnvironment="PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
    "${K3S_HOST_FIREWALL_DROPIN_MARKER}" "${K3S_HOST_FIREWALL_WRAPPER_DIR}" \
    | tee "${K3S_HOST_FIREWALL_DROPIN_FILE}" >/dev/null
  k3s_host_firewall_restart_k3s
}

k3s_host_firewall_prepare() {
  local iptables_version
  iptables_version="$(iptables --version 2>/dev/null || true)"
  if [[ "${iptables_version}" == *"nf_tables"* ]] && k3s_host_firewall_legacy_forward_drops; then
    info "install-offline: detected nft default with legacy FORWARD DROP; configuring k3s legacy xtables PATH"
    k3s_host_firewall_install_legacy_xtables
    return 0
  fi
  k3s_host_firewall_remove_legacy_xtables
}
