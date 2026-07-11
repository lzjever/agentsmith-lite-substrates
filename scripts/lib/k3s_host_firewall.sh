#!/usr/bin/env bash

readonly K3S_HOST_FIREWALL_WRAPPER_DIR="${K3S_HOST_FIREWALL_WRAPPER_DIR:-/usr/local/lib/agentsmith-lite/k3s-xtables}"
readonly K3S_HOST_FIREWALL_DROPIN_FILE="${K3S_HOST_FIREWALL_DROPIN_FILE:-/etc/systemd/system/k3s.service.d/10-agentsmith-lite-legacy-xtables.conf}"
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
  local candidate
  while IFS= read -r candidate; do
    command -v "${candidate}" >/dev/null 2>&1 && { command -v "${candidate}"; return 0; }
  done < <(k3s_host_firewall_legacy_tool_candidates "$1")
  return 1
}

k3s_host_firewall_needs_legacy_xtables() {
  local iptables_version
  iptables_version="$(iptables --version 2>/dev/null || true)"
  [[ "${iptables_version}" == *"nf_tables"* ]] \
    && command -v iptables-legacy >/dev/null 2>&1 \
    && iptables-legacy -S FORWARD 2>/dev/null | grep -Fx -- '-P FORWARD DROP' >/dev/null
}

k3s_host_firewall_require_legacy_xtables() {
  local tool
  for tool in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
    k3s_host_firewall_legacy_tool "${tool}" >/dev/null \
      || die "mixed nft/legacy iptables host requires legacy xtables tools; missing legacy ${tool} binary"
  done
}

k3s_host_firewall_render_dropin() {
  printf '%s\n[Service]\nEnvironment="PATH=%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
    "${K3S_HOST_FIREWALL_DROPIN_MARKER}" "${K3S_HOST_FIREWALL_WRAPPER_DIR}"
}

k3s_host_firewall_dropin_is_current() {
  [[ -f "${K3S_HOST_FIREWALL_DROPIN_FILE}" ]] \
    && cmp -s "${K3S_HOST_FIREWALL_DROPIN_FILE}" <(k3s_host_firewall_render_dropin)
}

k3s_host_firewall_install_legacy_xtables() {
  local tool legacy_tool temporary_dropin
  k3s_host_firewall_require_legacy_xtables
  mkdir -p "${K3S_HOST_FIREWALL_WRAPPER_DIR}" "$(dirname "${K3S_HOST_FIREWALL_DROPIN_FILE}")"
  for tool in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
    legacy_tool="$(k3s_host_firewall_legacy_tool "${tool}")"
    ln -sfn "${legacy_tool}" "${K3S_HOST_FIREWALL_WRAPPER_DIR}/${tool}"
  done

  if k3s_host_firewall_dropin_is_current; then
    return 0
  fi

  temporary_dropin="$(mktemp "${K3S_HOST_FIREWALL_DROPIN_FILE}.tmp.XXXXXX")"
  k3s_host_firewall_render_dropin >"${temporary_dropin}"
  mv -f -- "${temporary_dropin}" "${K3S_HOST_FIREWALL_DROPIN_FILE}"
  systemctl daemon-reload
  systemctl try-restart k3s.service
}

k3s_host_firewall_prepare() {
  if k3s_host_firewall_needs_legacy_xtables; then
    info "install-offline: detected nft default with legacy FORWARD DROP; configuring k3s legacy xtables PATH"
    k3s_host_firewall_install_legacy_xtables
  fi
}
