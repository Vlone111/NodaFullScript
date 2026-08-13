#!/usr/bin/env bash
#
# rw-edge-install.sh — Remnawave edge installer.
#
# Builds a 443-only edge on a fresh Debian/Ubuntu host: HAProxy in front, Caddy
# serving a real cover site, a pinned Remnawave node running Xray behind them,
# and any combination of the supported transports.
#
# It never talks to the Panel. It renders exact values and prints the steps to
# enter there by hand.
#
# GENERATED FILE — edit installer/parts/*.sh and run installer/build.sh.

set -Eeuo pipefail
umask 077

# ---------------------------------------------------------------- constants --

readonly SCRIPT_VERSION='1.0.0'
readonly INSTALL_DIR='/opt/rw-edge'
readonly PRIVATE_DIR="${INSTALL_DIR}/private"
readonly SITE_DIR="${INSTALL_DIR}/site"
readonly CERT_DIR="${INSTALL_DIR}/certs"
readonly STATE_FILE="${PRIVATE_DIR}/state.env"

# Digest-pinned so a silent upstream retag cannot change what runs here.
readonly NODE_IMAGE='remnawave/node@sha256:03f14935751b4ab565181e2b1766ccd1a9ac349d6839acd3ee49014e543fa232'
readonly CADDY_IMAGE='caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648'
readonly HAPROXY_IMAGE='haproxy@sha256:79799e8b2977e60802774fa53d29e6b54e045402cdd8a8b9fe43923e7095a047'
readonly NODE_EXPORTER_IMAGE='prom/node-exporter@sha256:d00a542e409ee618a4edc67da14dd48c5da66726bbd5537ab2af9c1dfc442c8a'
readonly BLACKBOX_IMAGE='prom/blackbox-exporter@sha256:e753ff9f3fc458d02cca5eddab5a77e1c175eee484a8925ac7d524f04366c2fc'
readonly VMAGENT_IMAGE='victoriametrics/vmagent@sha256:d564816bfef75b275c4032d681e4b5a8b9f8b3c1ca5381c40612a70bdb17afda'

# Loopback backends. Nothing here is ever exposed by the firewall.
readonly PORT_CADDY_TLS=19443       # Caddy TLS: cover site + h2c origins + ACME
readonly PORT_CADDY_PLAIN=19080     # plain HTTP origin for Hysteria2 masquerade
readonly PORT_HAPROXY_STATS=8404
readonly BACKEND_REALITY_TCP=18443
readonly BACKEND_XHTTP_TLS=18444
readonly BACKEND_REALITY_XHTTP=18445
readonly BACKEND_TCP_TLS=18446
readonly BACKEND_GRPC_TLS=18447
readonly BACKEND_REALITY_XHTTP_BORROW=18448

readonly DEFAULT_SITE_REPO='https://github.com/Vlone111/bitrail'
readonly DEFAULT_SITE_REF='site-v2'

# --------------------------------------------------------------- variant map --

# id|label|needs_domain|needs_cert|backend_port|panel_protocol
readonly -a VARIANTS=(
  'reality-tcp-steal|VLESS TCP + REALITY (self-steal, свой домен)|1|1|18443|vless'
  'reality-tcp-borrow|VLESS TCP + REALITY (чужой SNI-донор)|0|0|18443|vless'
  'reality-xhttp-steal|VLESS XHTTP + REALITY (self-steal)|1|1|18445|vless'
  'reality-xhttp-borrow|VLESS XHTTP + REALITY (чужой SNI-донор, без домена)|0|0|18448|vless'
  'xhttp-tls|VLESS XHTTP + TLS (за Caddy)|1|1|18444|vless'
  'grpc-tls|VLESS gRPC + TLS (за Caddy)|1|1|18447|vless'
  'tcp-tls|VLESS TCP + TLS (Xray терминирует)|1|1|18446|vless'
  'hysteria2|Hysteria2 на UDP/443 с masquerade на сайт|1|1|443|hysteria'
)

variant_field() {
  # variant_field <id> <1..6>
  local id="$1" idx="$2" row
  for row in "${VARIANTS[@]}"; do
    [[ "${row%%|*}" == "${id}" ]] || continue
    printf '%s' "$(printf '%s' "${row}" | cut -d'|' -f"${idx}")"
    return 0
  done
  return 1
}

variant_label()    { variant_field "$1" 2; }
variant_needs_dom(){ variant_field "$1" 3; }
variant_needs_crt(){ variant_field "$1" 4; }
variant_backend()  { variant_field "$1" 5; }

# ------------------------------------------------------------------ helpers --

if [[ -t 1 ]]; then
  readonly C_RESET=$'\033[0m' C_DIM=$'\033[2m' C_RED=$'\033[31m'
  readonly C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BOLD=$'\033[1m'
else
  readonly C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BOLD=''
fi

log()  { printf '%s[ok]%s   %s\n'   "${C_GREEN}"  "${C_RESET}" "$*"; }
info() { printf '%s[..]%s   %s\n'   "${C_DIM}"    "${C_RESET}" "$*"; }
warn() { printf '%s[!!]%s   %s\n'   "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()  { printf '%s[xx]%s   %s\n'   "${C_RED}"    "${C_RESET}" "$*" >&2; exit 1; }

section() {
  printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"
  printf '%s\n' "$(printf '%.0s-' $(seq 1 ${#1}))"
}

# Under `bash <(curl ...)` $0 is a file descriptor path like /dev/fd/63, which
# is useless in a message telling the operator what to run next.
if [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/self/fd/* ]]; then
  SELF_CMD="$0"
else
  SELF_CMD="${INSTALL_DIR}/rw-edge-install.sh"
fi
readonly SELF_CMD

on_error() {
  local code=$? line=${BASH_LINENO[0]}
  printf '\n%s[xx]%s   Прервано на строке %s (код %s).\n' \
    "${C_RED}" "${C_RESET}" "${line}" "${code}" >&2
  printf '      Состояние: %s\n' "${STATE_FILE}" >&2
  printf '      Ничего из уже поднятого не удаляется автоматически.\n' >&2
  printf '      Откат: %s rollback\n' "${SELF_CMD}" >&2
}
trap on_error ERR

# Keep a copy of ourselves on disk so `rollback`, `verify` and `steps` remain
# available after a one-shot `bash <(curl ...)` run.
self_install() {
  [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/self/fd/* ]] || return 0
  [[ "$(readlink -f "$0")" != "$(readlink -f "${INSTALL_DIR}/rw-edge-install.sh" 2>/dev/null)" ]] || return 0
  install -m 0700 "$0" "${INSTALL_DIR}/rw-edge-install.sh" 2>/dev/null || true
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Нет команды '$1'. Установите её и повторите."; }

# ask <prompt> <default> -> echoes answer
#
# The default goes on its own line. Long prompt plus long default reaches the
# 80-column boundary and the terminal truncates it mid-word, which looks like
# the installer corrupted its own output. The prompt is written to stderr so
# command substitution captures only the answer.
ask() {
  local prompt="$1" default="${2:-}" reply=''
  if [[ -n "${default}" ]]; then
    printf '%s\n  [%s]: ' "${prompt}" "${default}" >&2
    read -r reply </dev/tty || true
    printf '%s' "${reply:-${default}}"
  else
    printf '%s: ' "${prompt}" >&2
    read -r reply </dev/tty || true
    printf '%s' "${reply}"
  fi
}

ask_required() {
  local prompt="$1" value
  while :; do
    value="$(ask "${prompt}")"
    [[ -n "${value}" ]] && { printf '%s' "${value}"; return 0; }
    warn 'Значение обязательно.'
  done
}

ask_secret() {
  local prompt="$1" reply=''
  read -r -s -p "${prompt}: " reply </dev/tty || true
  printf '\n' >&2
  printf '%s' "${reply}"
}

confirm() {
  local prompt="$1" reply=''
  read -r -p "${prompt} [y/N]: " reply </dev/tty || true
  [[ "${reply}" =~ ^[Yy]$ ]]
}

confirm_typed() {
  # Destructive or outward-facing steps require typing the word, not a keypress.
  local prompt="$1" word="$2" reply=''
  read -r -p "${prompt} (введите ${word}): " reply </dev/tty || true
  [[ "${reply}" == "${word}" ]]
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

is_fqdn() {
  [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

port_free() { ! ss -lntuH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$1\$"; }

rand_hex() { openssl rand -hex "$1"; }

# ------------------------------------------------------------------- state ---

save_state() {
  mkdir -p "${PRIVATE_DIR}"
  {
    printf '# rw-edge state, written %s by installer %s\n' "$(date -Is)" "${SCRIPT_VERSION}"
    printf 'SCRIPT_VERSION=%q\n' "${SCRIPT_VERSION}"
    printf 'EDGE_IPV4=%q\n' "${EDGE_IPV4}"
    printf 'PANEL_IPV4=%q\n' "${PANEL_IPV4}"
    printf 'NODE_PORT=%q\n' "${NODE_PORT}"
    printf 'NODE_CODE=%q\n' "${NODE_CODE}"
    printf 'ACME_EMAIL=%q\n' "${ACME_EMAIL}"
    printf 'SELECTED=%q\n' "${SELECTED[*]}"
    printf 'SITE_REPO=%q\n' "${SITE_REPO}"
    printf 'SITE_REF=%q\n' "${SITE_REF}"
    printf 'SITE_DOMAIN=%q\n' "${SITE_DOMAIN}"
    printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY}"
    printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY}"
    printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID}"
    printf 'XHTTP_PATH=%q\n' "${XHTTP_PATH}"
    printf 'GRPC_SERVICE=%q\n' "${GRPC_SERVICE}"
    printf 'BORROW_SNI=%q\n' "${BORROW_SNI:-}"
    printf 'METRICS_URL=%q\n' "${METRICS_URL:-}"
    printf 'METRICS_USER=%q\n' "${METRICS_USER:-}"
    local v
    for v in "${SELECTED[@]}"; do
      printf 'DOMAIN_%s=%q\n' "${v//-/_}" "${DOMAINS[$v]:-}"
    done
  } >"${STATE_FILE}"
  chmod 0600 "${STATE_FILE}"
}

load_state() {
  [[ -f "${STATE_FILE}" ]] || return 1
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  read -r -a SELECTED <<<"${SELECTED}"
  declare -gA DOMAINS=()
  local v key
  for v in "${SELECTED[@]}"; do
    key="DOMAIN_${v//-/_}"
    DOMAINS[$v]="${!key:-}"
  done
  return 0
}
