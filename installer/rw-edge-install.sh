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

readonly DEFAULT_SITE_REPO='https://github.com/Vlone111/bitrail'
readonly DEFAULT_SITE_REF='site-v2'

# --------------------------------------------------------------- variant map --

# id|label|needs_domain|needs_cert|backend_port|panel_protocol
readonly -a VARIANTS=(
  'reality-tcp-steal|VLESS TCP + REALITY (self-steal, свой домен)|1|1|18443|vless'
  'reality-tcp-borrow|VLESS TCP + REALITY (чужой SNI-донор)|0|0|18443|vless'
  'reality-xhttp-steal|VLESS XHTTP + REALITY (self-steal)|1|1|18445|vless'
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

# set -E передаёт трап в функции и подоболочки, поэтому при ошибке внутри
# вложенного вызова он срабатывает на каждом уровне и печатает одно и то же
# сообщение несколько раз. Флаг оставляет только первое.
RW_ERR_REPORTED=0
on_error() {
  local code=$? line=${BASH_LINENO[0]}
  [[ "${RW_ERR_REPORTED}" == '1' ]] && exit "${code}"
  RW_ERR_REPORTED=1
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

# =============================================================== preflight ====

preflight() {
  section 'Проверка окружения'

  [[ ${EUID} -eq 0 ]] || die 'Запускать нужно от root.'
  [[ -r /etc/os-release ]] || die 'Не найден /etc/os-release.'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *) die "Поддерживаются Debian и Ubuntu. Обнаружено: ${PRETTY_NAME:-${ID}}." ;;
  esac
  log "ОС: ${PRETTY_NAME:-${ID}}"

  local pkgs=(ca-certificates curl dnsutils jq openssl iproute2 ufw git)
  local missing=() p
  for p in "${pkgs[@]}"; do
    dpkg -s "${p}" >/dev/null 2>&1 || missing+=("${p}")
  done
  if (( ${#missing[@]} )); then
    info "Ставлю пакеты: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  fi
  log 'Базовые пакеты на месте.'

  local port
  for port in 443 "${PORT_CADDY_TLS}" "${PORT_CADDY_PLAIN}" "${PORT_HAPROXY_STATS}"; do
    port_free "${port}" || warn "Порт ${port} уже занят. Если это прошлый запуск — продолжаем, иначе прервите."
  done

  EDGE_IPV4="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  is_ipv4 "${EDGE_IPV4}" || EDGE_IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  is_ipv4 "${EDGE_IPV4}" || die 'Не удалось определить публичный IPv4 узла.'
  log "Публичный IPv4: ${EDGE_IPV4}"

  if [[ -z "$(ip -6 addr show scope global 2>/dev/null)" ]]; then
    info 'Глобального IPv6 нет — конфиги собираются как IPv4-only, AAAA создавать нельзя.'
  else
    warn 'У узла есть глобальный IPv6, но конфиги всё равно IPv4-only (queryStrategy UseIPv4). Не создавайте AAAA, пока путь по IPv6 не проверен отдельно.'
  fi
}

# ============================================================= questionnaire ==

ask_panel() {
  section 'Панель Remnawave'

  while :; do
    PANEL_IPV4="$(ask_required 'IP адрес панели (только он получит доступ к Node API)')"
    is_ipv4 "${PANEL_IPV4}" && break
    warn 'Нужен корректный IPv4.'
  done

  while :; do
    NODE_PORT="$(ask 'Порт Node API' '3334')"
    [[ "${NODE_PORT}" =~ ^[0-9]{2,5}$ ]] && (( NODE_PORT > 0 && NODE_PORT < 65536 )) && break
    warn 'Нужен номер порта 1-65535.'
  done

  printf '\n  Создайте Node в панели и скопируйте выданный SECRET_KEY.\n'
  printf '  Ввод скрыт, значение попадёт только в %s с правами 0600.\n\n' "${PRIVATE_DIR}/node.env"
  while :; do
    NODE_SECRET="$(ask_secret 'SECRET_KEY ноды')"
    [[ -n "${NODE_SECRET}" ]] || { warn 'Пустое значение.'; continue; }
    if printf '%s' "${NODE_SECRET}" | base64 -d 2>/dev/null | jq -e 'has("nodeCertPem") and has("nodeKeyPem")' >/dev/null 2>&1; then
      log 'Ключ разобран, сертификат и приватный ключ на месте.'
      break
    fi
    warn 'Это не похоже на SECRET_KEY Remnawave (base64 с nodeCertPem/nodeKeyPem). Повторите.'
  done

  ACME_EMAIL="$(ask 'E-mail для Let'\''s Encrypt' "admin@${PANEL_IPV4}.nip.io")"
  NODE_CODE="$(ask 'Короткий код узла для тегов (A-Z0-9)' 'EDGE1')"
  NODE_CODE="${NODE_CODE^^}"
  NODE_CODE="${NODE_CODE//[^A-Z0-9]/}"
  [[ -n "${NODE_CODE}" ]] || NODE_CODE='EDGE1'
}

ask_variants() {
  section 'Какие транспорты поднять'

  printf '  Можно выбрать несколько — номера через пробел или запятую.\n\n'
  local i=1 row id label
  for row in "${VARIANTS[@]}"; do
    id="${row%%|*}"
    label="$(printf '%s' "${row}" | cut -d'|' -f2)"
    printf '   %d) %-22s %s\n' "${i}" "${id}" "${label}"
    i=$((i + 1))
  done
  printf '\n'

  local raw picked=() n
  while :; do
    raw="$(ask_required 'Номера через пробел')"
    raw="${raw//,/ }"
    picked=()
    local bad=0
    for n in ${raw}; do
      [[ "${n}" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#VARIANTS[@]} )) || { bad=1; break; }
      picked+=("$(printf '%s' "${VARIANTS[$((n - 1))]}" | cut -d'|' -f1)")
    done
    (( bad == 0 )) && (( ${#picked[@]} > 0 )) || { warn "Введите номера от 1 до ${#VARIANTS[@]}."; continue; }

    # dedupe, order preserved
    SELECTED=()
    local p seen
    for p in "${picked[@]}"; do
      seen=0
      for n in "${SELECTED[@]:-}"; do [[ "${n}" == "${p}" ]] && seen=1; done
      (( seen == 0 )) && SELECTED+=("${p}")
    done

    if validate_selection; then break; fi
  done

  printf '\n  Выбрано:\n'
  local v
  for v in "${SELECTED[@]}"; do
    printf '   - %s — %s\n' "${v}" "$(variant_label "${v}")"
  done
}

validate_selection() {
  local has_steal=0 has_borrow=0 v
  for v in "${SELECTED[@]}"; do
    [[ "${v}" == 'reality-tcp-steal'  ]] && has_steal=1
    [[ "${v}" == 'reality-tcp-borrow' ]] && has_borrow=1
  done

  if (( has_steal == 1 && has_borrow == 1 )); then
    warn 'reality-tcp-steal и reality-tcp-borrow несовместимы: оба занимают один RAW-инбаунд и один default_backend HAProxy. Выберите один.'
    return 1
  fi
  return 0
}

ask_domains() {
  section 'Домены'

  declare -gA DOMAINS=()
  local need=() v
  for v in "${SELECTED[@]}"; do
    [[ "$(variant_needs_dom "${v}")" == '1' ]] && need+=("${v}")
  done

  if (( ${#need[@]} == 0 )); then
    SITE_DOMAIN=''
    info 'Ни одному из выбранных вариантов собственный домен не нужен.'
    return 0
  fi

  printf '  Нужно доменов: %d. Для каждого заранее сделайте A-запись на %s.\n' \
    "${#need[@]}" "${EDGE_IPV4}"
  printf '  AAAA не создавайте: на узле нет глобального IPv6.\n'
  printf '  Один домен — один транспорт: на TCP/443 разводка идёт по SNI.\n\n'

  local d used
  for v in "${need[@]}"; do
    while :; do
      d="$(ask_required "Домен для ${v}")"
      d="${d,,}"
      if ! is_fqdn "${d}"; then warn 'Нужно полное доменное имя.'; continue; fi
      used=0
      local k
      for k in "${!DOMAINS[@]}"; do
        [[ "${DOMAINS[$k]}" == "${d}" ]] && used=1
      done
      if (( used == 1 )) && [[ "${v}" != 'hysteria2' ]]; then
        warn 'Этот домен уже занят другим транспортом. На TCP/443 так нельзя.'
        continue
      fi
      if (( used == 1 )) && [[ "${v}" == 'hysteria2' ]]; then
        info 'Hysteria2 живёт на UDP/443, переиспользование домена допустимо.'
      fi
      DOMAINS[$v]="${d}"
      break
    done
  done

  # Cover site is served on the first domain that owns a certificate.
  SITE_DOMAIN=''
  for v in "${SELECTED[@]}"; do
    if [[ "$(variant_needs_crt "${v}")" == '1' && -n "${DOMAINS[$v]:-}" ]]; then
      SITE_DOMAIN="${DOMAINS[$v]}"
      break
    fi
  done

  local has_borrow=0
  for v in "${SELECTED[@]}"; do [[ "${v}" == 'reality-tcp-borrow' ]] && has_borrow=1; done
  if (( has_borrow == 1 )); then
    printf '\n  Донорский SNI для reality-tcp-borrow. Требования: TLS 1.3, X25519,\n'
    printf '  чужой домен, не в РФ, стабильно доступен с этого узла.\n'
    while :; do
      BORROW_SNI="$(ask 'Домен-донор' 'www.samsung.com')"
      is_fqdn "${BORROW_SNI}" && break
      warn 'Нужно полное доменное имя.'
    done
  else
    BORROW_SNI=''
  fi
}

verify_dns() {
  local need=() v
  for v in "${SELECTED[@]}"; do
    [[ "$(variant_needs_dom "${v}")" == '1' ]] && need+=("${v}")
  done
  (( ${#need[@]} )) || return 0

  section 'Проверка DNS'

  local checked=() d done_already
  for v in "${need[@]}"; do
    d="${DOMAINS[$v]}"
    done_already=0
    local c
    for c in "${checked[@]:-}"; do [[ "${c}" == "${d}" ]] && done_already=1; done
    (( done_already == 1 )) && continue
    checked+=("${d}")
    verify_one_domain "${d}"
  done
  log 'DNS проверен.'
}

# `|| true` здесь обязательны. В скрипте включён pipefail, поэтому статусом
# конвейера становится код dig, а не успешного tail. Недоступный резолвер даёт
# код 9, и set -e убивал установку прямо на проверке DNS — притом что сама
# проверка ничего не настраивает и права ронять установку не имеет.
verify_one_domain() {
  local domain="$1" resolver answer ok=0 unreachable=0 wrong=0

  local rc
  for resolver in 9.9.9.9 77.88.8.8; do
    rc=0
    answer="$(dig +short +time=4 +tries=2 "@${resolver}" "${domain}" A 2>/dev/null | tail -1)" || rc=$?
    # Недоступность ловится по коду возврата, а не по пустой строке: `dig
    # +short` печатает ";; no servers could be reached" в stdout, и проверка на
    # пустоту принимала это за неверный ответ.
    if (( rc != 0 )) || [[ -z "${answer}" || "${answer}" == *"no servers could be reached"* ]]; then
      unreachable=$((unreachable + 1))
      warn "${resolver} не ответил."
    elif [[ "${answer}" == "${EDGE_IPV4}" ]]; then
      ok=$((ok + 1))
    else
      wrong=$((wrong + 1))
      warn "${domain} через ${resolver} → '${answer}', ожидался ${EDGE_IPV4}."
    fi
  done

  # Оба внешних резолвера молчат — почти всегда это провайдер режет исходящий
  # UDP/53, а не проблема с записью. Спрашиваем системный: он менее надёжен как
  # свидетель (может отдать из кеша), но отличает «DNS не настроен» от «до
  # резолверов не достучаться».
  if (( ok == 0 && unreachable == 2 )); then
    answer="$(dig +short +time=4 "${domain}" A 2>/dev/null | tail -1 || true)"
    if [[ "${answer}" == "${EDGE_IPV4}" ]]; then
      warn "Внешние резолверы недоступны с этого узла — похоже, режется исходящий UDP/53."
      warn "Системный резолвер отвечает верно: ${domain} → ${EDGE_IPV4}. Считаю запись корректной."
      ok=2
    fi
  fi

  local aaaa
  aaaa="$(dig +short +time=4 "@9.9.9.9" "${domain}" AAAA 2>/dev/null | tail -1 || true)"
  [[ -n "${aaaa}" ]] && warn "У ${domain} есть AAAA (${aaaa}). Клиенты пойдут по IPv6, которого на узле нет. Удалите запись."

  # Достаточно одного верного ответа при отсутствии неверных. Требование двух
  # совпадений из двух означало, что недоступный с этого узла резолвер — а это
  # обычное дело, провайдеры режут исходящий UDP/53 — заставлял подтверждать
  # руками запись, которая на самом деле верна.
  if (( ok >= 1 && wrong == 0 )); then
    log "${domain} → ${EDGE_IPV4}"
    (( unreachable > 0 )) && warn "Часть резолверов недоступна с этого узла, но доступные отвечают верно."
  else
    if ! confirm "DNS для ${domain} ещё не сошёлся. Продолжить всё равно"; then
      die 'Дождитесь распространения DNS и запустите снова.'
    fi
  fi
}

ask_site() {
  section 'Сайт прикрытия'

  printf '  Скрипт скачает статический сайт из вашего git-репозитория и положит\n'
  printf '  его за Caddy. Указывайте тег, а не ветку: так выкат воспроизводим.\n\n'

  SITE_REPO="$(ask 'Git URL репозитория с сайтом' "${DEFAULT_SITE_REPO}")"
  SITE_REF="$(ask 'Тег или коммит' "${DEFAULT_SITE_REF}")"
}

generate_material() {
  section 'Генерация ключей и путей'

  # Only what the selected transports actually consume. Generating everything
  # unconditionally is harmless in the configs but makes the summary claim work
  # that was never needed, and an installer whose output cannot be trusted is
  # worse than one that says less.
  REALITY_PRIVATE_KEY=''
  REALITY_PUBLIC_KEY=''
  REALITY_SHORT_ID=''
  XHTTP_PATH=''
  GRPC_SERVICE=''

  local made=()

  if has_variant reality-tcp-steal || has_variant reality-tcp-borrow \
     || has_variant reality-xhttp-steal; then
    local keys
    keys="$(docker run --rm --pull never --network none --cap-drop ALL --read-only \
      --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" x25519)"
    REALITY_PRIVATE_KEY="$(printf '%s\n' "${keys}" | sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' | head -n1)"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "${keys}" | sed -nE 's/^(Password \(PublicKey\)|Password|PublicKey|Public key):[[:space:]]*//p' | head -n1)"
    [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] \
      || die 'Xray не выдал пару ключей REALITY.'
    REALITY_SHORT_ID="$(rand_hex 8)"
    made+=('пара ключей REALITY и short ID')
  fi

  if has_variant reality-xhttp-steal || has_variant xhttp-tls; then
    XHTTP_PATH="/api/v1/$(rand_hex 24)/"
    made+=('XHTTP-путь')
  fi

  if has_variant grpc-tls; then
    GRPC_SERVICE="api.v1.$(rand_hex 6)"
    made+=('имя gRPC-сервиса')
  fi

  if (( ${#made[@]} )); then
    local item
    for item in "${made[@]}"; do log "Сгенерировано: ${item}"; done
  else
    info 'Генерировать нечего: выбранным транспортам ключи и пути не нужны.'
  fi
}

# ============================================================== generators ====

variant_tag() {
  local id="${1//-/_}"
  printf 'RW_%s_%s' "${NODE_CODE}" "${id^^}"
}

has_variant() {
  local want="$1" v
  for v in "${SELECTED[@]}"; do [[ "${v}" == "${want}" ]] && return 0; done
  return 1
}

cert_domains() {
  # Unique list of domains that need a public certificate.
  local v d list=()
  for v in "${SELECTED[@]}"; do
    [[ "$(variant_needs_crt "${v}")" == '1' ]] || continue
    d="${DOMAINS[$v]:-}"
    [[ -n "${d}" ]] || continue
    local seen=0 o
    for o in "${list[@]:-}"; do [[ "${o}" == "${d}" ]] && seen=1; done
    (( seen == 0 )) && list+=("${d}")
  done
  printf '%s\n' "${list[@]:-}"
}

# --------------------------------------------------------- cover site fetch --

render_site() {
  section 'Сайт прикрытия'

  rm -rf "${SITE_DIR}.new"
  info "Клонирую ${SITE_REPO} (${SITE_REF})"
  if ! git clone --quiet --depth 1 --branch "${SITE_REF}" "${SITE_REPO}" "${SITE_DIR}.new" 2>/dev/null; then
    rm -rf "${SITE_DIR}.new"
    die "Не удалось склонировать ${SITE_REPO} на теге ${SITE_REF}. Проверьте URL, тег и доступность."
  fi
  rm -rf "${SITE_DIR}.new/.git"

  [[ -f "${SITE_DIR}.new/index.html" ]] || die 'В репозитории нет index.html в корне.'

  if [[ -n "${SITE_DOMAIN}" ]]; then
    grep -rl '__SITE_DOMAIN__' "${SITE_DIR}.new" 2>/dev/null \
      | xargs -r sed -i "s/__SITE_DOMAIN__/${SITE_DOMAIN}/g"
    log "Подставил домен ${SITE_DOMAIN} в canonical, robots.txt и sitemap.xml."
  fi

  # Tested with -f, not -x, and invoked through bash: a repository pushed from
  # Windows arrives without the executable bit, and an -x test would silently
  # skip media generation instead of failing loudly.
  if [[ -f "${SITE_DIR}.new/tools/make-assets.sh" ]]; then
    if [[ -d "${SITE_DIR}/media" ]]; then
      info 'Медиа уже сгенерировано ранее, переиспользую.'
      mv "${SITE_DIR}/media" "${SITE_DIR}.new/media"
    else
      info 'Генерирую медиа. Это единственный шаг, который нагружает CPU, и он разовый.'
      dpkg -s ffmpeg >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg >/dev/null
      # stdin from /dev/null: ffmpeg reads stdin by default and leaves the
      # terminal in a non-canonical mode, after which later prompts silently
      # return the wrong answer.
      bash "${SITE_DIR}.new/tools/make-assets.sh" "${SITE_DIR}.new/media" </dev/null \
        || die 'Генерация медиа не удалась.'
    fi
  else
    warn 'В репозитории нет tools/make-assets.sh — сайт будет без медиа.'
  fi

  rm -rf "${SITE_DIR}"
  mv "${SITE_DIR}.new" "${SITE_DIR}"
  chmod -R a+rX "${SITE_DIR}"
  log "Сайт разложен в ${SITE_DIR}: $(find "${SITE_DIR}" -type f | wc -l) файлов, $(du -sh "${SITE_DIR}" | cut -f1)."
}

# ------------------------------------------------------ server xray profile --

render_xray_profile() {
  local out="${PRIVATE_DIR}/config-profile.json"
  local inbounds='[]' v tag dom

  for v in "${SELECTED[@]}"; do
    tag="$(variant_tag "${v}")"
    dom="${DOMAINS[$v]:-}"
    case "${v}" in
      reality-tcp-steal|reality-tcp-borrow)
        local sni target
        if [[ "${v}" == 'reality-tcp-steal' ]]; then
          sni="${dom}"; target="127.0.0.1:${PORT_CADDY_TLS}"
        else
          sni="${BORROW_SNI}"; target="${BORROW_SNI}:443"
        fi
        inbounds="$(printf '%s' "${inbounds}" | jq \
          --arg tag "${tag}" --arg sni "${sni}" --arg target "${target}" \
          --arg pk "${REALITY_PRIVATE_KEY}" --arg sid "${REALITY_SHORT_ID}" \
          --argjson port "${BACKEND_REALITY_TCP}" '. + [{
            tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
            settings: {clients: [], decryption: "none", flow: "xtls-rprx-vision"},
            streamSettings: {
              network: "raw", security: "reality",
              realitySettings: {show: false, target: $target, xver: 0,
                serverNames: [$sni], privateKey: $pk, shortIds: [$sid]},
              sockopt: {acceptProxyProtocol: true}
            },
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: true}
          }]')"
        ;;
      reality-xhttp-steal)
        inbounds="$(printf '%s' "${inbounds}" | jq \
          --arg tag "${tag}" --arg sni "${dom}" --arg path "${XHTTP_PATH}" \
          --arg pk "${REALITY_PRIVATE_KEY}" --arg sid "${REALITY_SHORT_ID}" \
          --arg target "127.0.0.1:${PORT_CADDY_TLS}" \
          --argjson port "${BACKEND_REALITY_XHTTP}" '. + [{
            tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
            settings: {clients: [], decryption: "none", flow: ""},
            streamSettings: {
              network: "xhttp", security: "reality",
              xhttpSettings: {path: $path, mode: "auto"},
              realitySettings: {show: false, target: $target, xver: 0,
                serverNames: [$sni], privateKey: $pk, shortIds: [$sid]},
              sockopt: {acceptProxyProtocol: true}
            },
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: true}
          }]')"
        ;;
      xhttp-tls)
        inbounds="$(printf '%s' "${inbounds}" | jq \
          --arg tag "${tag}" --arg path "${XHTTP_PATH}" \
          --argjson port "${BACKEND_XHTTP_TLS}" '. + [{
            tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
            settings: {clients: [], decryption: "none", flow: ""},
            streamSettings: {network: "xhttp", security: "none",
              xhttpSettings: {path: $path, mode: "auto"}},
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: true}
          }]')"
        ;;
      grpc-tls)
        inbounds="$(printf '%s' "${inbounds}" | jq \
          --arg tag "${tag}" --arg svc "${GRPC_SERVICE}" \
          --argjson port "${BACKEND_GRPC_TLS}" '. + [{
            tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
            settings: {clients: [], decryption: "none", flow: ""},
            streamSettings: {network: "grpc", security: "none",
              grpcSettings: {serviceName: $svc}},
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: true}
          }]')"
        ;;
      tcp-tls)
        inbounds="$(printf '%s' "${inbounds}" | jq \
          --arg tag "${tag}" \
          --arg crt "/etc/rw-certs/${dom}/fullchain.pem" \
          --arg key "/etc/rw-certs/${dom}/privkey.pem" \
          --argjson port "${BACKEND_TCP_TLS}" '. + [{
            tag: $tag, listen: "127.0.0.1", port: $port, protocol: "vless",
            settings: {clients: [], decryption: "none", flow: "xtls-rprx-vision"},
            streamSettings: {
              network: "raw", security: "tls",
              tlsSettings: {alpn: ["h2","http/1.1"], minVersion: "1.2",
                certificates: [{certificateFile: $crt, keyFile: $key, oneTimeLoading: false}]},
              sockopt: {acceptProxyProtocol: true}
            },
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: true}
          }]')"
        ;;
      hysteria2)
        # `clients` and `users` are aliases of the same HysteriaServerConfig
        # field; `clients` is used to match what Remnawave injects into.
        # masquerade belongs to the transport, not to settings: putting it in
        # settings parses without complaint and is then silently ignored.
        inbounds="$(printf '%s' "${inbounds}" | jq \
          --arg tag "${tag}" --arg sni "${dom}" \
          --arg crt "/etc/rw-certs/${dom}/fullchain.pem" \
          --arg key "/etc/rw-certs/${dom}/privkey.pem" \
          --arg masq "http://127.0.0.1:${PORT_CADDY_PLAIN}" '. + [{
            tag: $tag, listen: "0.0.0.0", port: 443, protocol: "hysteria",
            settings: {version: 2, clients: []},
            streamSettings: {
              network: "hysteria", security: "tls",
              finalmask: {quicParams: {debug: false, congestion: "bbr"}},
              tlsSettings: {alpn: ["h3"], serverName: $sni,
                certificates: [{certificateFile: $crt, keyFile: $key, oneTimeLoading: false}]},
              hysteriaSettings: {version: 2, udpIdleTimeout: 60,
                masquerade: {type: "proxy", url: $masq, rewriteHost: false, insecure: false}}
            },
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: true}
          }]')"
        ;;
      *) die "Внутренняя ошибка: неизвестный вариант ${v}." ;;
    esac
  done

  jq -n --argjson inbounds "${inbounds}" '{
    log: {loglevel: "warning"},
    dns: {
      tag: "dns-internal",
      queryStrategy: "UseIPv4",
      disableCache: false,
      servers: ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
    },
    inbounds: $inbounds,
    outbounds: [
      {tag: "DIRECT", protocol: "freedom", settings: {domainStrategy: "UseIPv4"}},
      {tag: "BLOCK", protocol: "blackhole"}
    ],
    routing: {
      domainStrategy: "IPIfNonMatch",
      rules: [
        {type: "field", inboundTag: ["dns-internal"], outboundTag: "DIRECT"},
        {type: "field", ip: ["geoip:private"], outboundTag: "BLOCK"},
        {type: "field", domain: ["geosite:private"], outboundTag: "BLOCK"},
        # Torrent from an exit node buys abuse complaints and nothing else.
        {type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK"},
        {type: "field", network: "tcp,udp", outboundTag: "DIRECT"}
      ]
    },
    policy: {
      levels: {"0": {statsUserUplink: true, statsUserDownlink: true, statsUserOnline: true}},
      system: {statsInboundUplink: true, statsInboundDownlink: true,
               statsOutboundUplink: true, statsOutboundDownlink: true}
    },
    stats: {}
  }' >"${out}"
  chmod 0600 "${out}"
  log "Серверный Config Profile: ${out}"
}

# ------------------------------------------------------------- haproxy.cfg ---

render_haproxy() {
  local out="${INSTALL_DIR}/haproxy.cfg" acls='' routes='' default_backend v dom

  for v in "${SELECTED[@]}"; do
    dom="${DOMAINS[$v]:-}"
    case "${v}" in
      reality-tcp-steal)
        acls+="    acl sni_${v//-/_} req.ssl_sni -i ${dom}"$'\n'
        routes+="    use_backend xray_reality_tcp if sni_${v//-/_}"$'\n'
        default_backend='xray_reality_tcp' ;;
      reality-tcp-borrow)
        default_backend='xray_reality_tcp' ;;
      reality-xhttp-steal)
        acls+="    acl sni_${v//-/_} req.ssl_sni -i ${dom}"$'\n'
        routes+="    use_backend xray_reality_xhttp if sni_${v//-/_}"$'\n' ;;
      tcp-tls)
        acls+="    acl sni_${v//-/_} req.ssl_sni -i ${dom}"$'\n'
        routes+="    use_backend xray_tcp_tls if sni_${v//-/_}"$'\n' ;;
      xhttp-tls|grpc-tls)
        acls+="    acl sni_${v//-/_} req.ssl_sni -i ${dom}"$'\n'
        routes+="    use_backend caddy_tls if sni_${v//-/_}"$'\n' ;;
      hysteria2)
        # Данные Hysteria2 идут по UDP, HAProxy их не видит — но домен-то
        # резолвится в этот же IP, и любой браузер или сканер постучится по
        # TCP/443 с этим SNI. Без явного правила он проваливался в
        # default_backend: при self-steal туда отвечал Caddy и всё выглядело
        # обычным сайтом, а при borrow REALITY уводил рукопожатие к донору и
        # домен предъявлял ЧУЖОЙ сертификат. Для человека это «сайт не
        # открывается», а для наблюдателя — готовая примета: домен на твоём IP
        # отдаёт чужой CN.
        acls+="    acl sni_${v//-/_} req.ssl_sni -i ${dom}"$'\n'
        routes+="    use_backend caddy_tls if sni_${v//-/_}"$'\n' ;;
    esac
  done

  # No REALITY on raw TCP means unknown SNI should still reach a real website.
  [[ -n "${default_backend:-}" ]] || default_backend='caddy_tls'

  {
    cat <<EOF
# Generated by rw-edge installer ${SCRIPT_VERSION}. Do not edit by hand.
global
    log stdout format raw local0
    maxconn 20000
    # The master runs as root to bind :443 and drops workers here; the compose
    # file grants exactly SETUID and SETGID for this and nothing more.
    user haproxy
    group haproxy
    # No admin stats socket: it is unused, and every failure mode it introduces
    # ends with HAProxy exiting and nothing listening on 443. The loopback HTTP
    # stats listener below covers what it was wanted for.

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    option dontlog-normal
    # Zero-copy forwarding: this proxy never inspects payload past ClientHello.
    option splice-auto
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout tunnel 4h
    timeout client-fin 30s
    timeout server-fin 30s

frontend public_tcp_443
    bind 0.0.0.0:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    # Evaluated before SNI: the ACME TLS-ALPN-01 challenge must reach Caddy
    # whatever hostname it carries, or renewal silently stops working.
    acl is_acme req.ssl_alpn -m sub acme-tls/1
    use_backend caddy_tls if is_acme

EOF
    printf '%s' "${acls}"
    printf '\n'
    printf '%s' "${routes}"
    cat <<EOF

    default_backend ${default_backend}

backend caddy_tls
    # rise 1 and a short interval on purpose: Caddy starts ACME the moment it
    # boots, and with the default two successful checks this backend is still
    # DOWN for the first ten seconds. Every validation attempt in that window
    # fails and burns an ACME order for nothing.
    server caddy_local 127.0.0.1:${PORT_CADDY_TLS} check inter 2s fall 3 rise 1
EOF
    if has_variant reality-tcp-steal || has_variant reality-tcp-borrow; then
      cat <<EOF

backend xray_reality_tcp
    server xray_local 127.0.0.1:${BACKEND_REALITY_TCP} send-proxy-v2 check inter 5s fall 3 rise 2
EOF
    fi
    if has_variant reality-xhttp-steal; then
      cat <<EOF

backend xray_reality_xhttp
    server xray_local 127.0.0.1:${BACKEND_REALITY_XHTTP} send-proxy-v2 check inter 5s fall 3 rise 2
EOF
    fi
    if has_variant tcp-tls; then
      cat <<EOF

backend xray_tcp_tls
    server xray_local 127.0.0.1:${BACKEND_TCP_TLS} send-proxy-v2 check inter 5s fall 3 rise 2
EOF
    fi
    cat <<EOF

listen local_stats
    bind 127.0.0.1:${PORT_HAPROXY_STATS}
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
EOF
  } >"${out}"
  chmod 0644 "${out}"
  log "HAProxy: ${out} (default_backend=${default_backend})"
}

# --------------------------------------------------------------- Caddyfile ---

render_caddyfile() {
  local out="${INSTALL_DIR}/Caddyfile" d v ACME_CA_LINE=''

  # Repeated end-to-end test runs burn Let's Encrypt rate limits fast: five
  # duplicate certificates per week per identical name set, and a failed run
  # still consumes orders. Staging has no such ceiling and issues an untrusted
  # certificate, which is fine when the point is to test the plumbing.
  if [[ "${RW_ACME_STAGING:-}" == '1' ]]; then
    ACME_CA_LINE=$'\n            dir https://acme-staging-v02.api.letsencrypt.org/directory'
    warn 'ACME staging: сертификаты будут НЕдоверенными. Только для тестов.'
  fi

  {
    cat <<EOF
# Generated by rw-edge installer ${SCRIPT_VERSION}. Do not edit by hand.
{
    admin off
    email ${ACME_EMAIL}
    http_port ${PORT_CADDY_PLAIN}
    https_port ${PORT_CADDY_TLS}
    auto_https disable_redirects
    servers {
        # UDP/443 is either closed or owned by Hysteria2, so never advertise H3.
        protocols h1 h2
    }
}

(site) {
    root * /srv

    # Compress text only. Media is already compressed, so running it through
    # zstd burns CPU on both ends and saves nothing.
    @text path *.html *.css *.svg *.txt *.xml *.json *.m3u8
    encode @text zstd gzip

    # Caddy does not know these out of the box, and a wrong Content-Type is
    # enough to stop HLS playing in every browser.
    @m3u8 path *.m3u8
    header @m3u8 Content-Type "application/vnd.apple.mpegurl"
    @m4s path *.m4s
    header @m4s Content-Type "video/iso.segment"
    @mpd path *.mpd
    header @mpd Content-Type "application/dash+xml"

    # Filenames never change contents, so media may be cached indefinitely.
    # The checksum list must not be, or new assets stay invisible.
    @media {
        path /media/*
        not path /media/SHA256SUMS
    }
    header @media Cache-Control "public, max-age=31536000, immutable"
    header /media/SHA256SUMS Cache-Control "public, max-age=300"
    header /assets/* Cache-Control "public, max-age=604800"

    header {
        -Server
        Referrer-Policy "no-referrer-when-downgrade"
        X-Content-Type-Options "nosniff"
    }

    file_server
}

# handle_errors is not an ordered handler, so it cannot live inside a handle
# block and has to be imported at site level.
(errors) {
    handle_errors {
        rewrite * /404.html
        root * /srv
        file_server
    }
}

(acme) {
    tls {
        issuer acme {
            # Port 80 is never opened; TLS-ALPN-01 arrives via HAProxy.
            disable_http_challenge${ACME_CA_LINE}
        }
    }
}
EOF

    while read -r d; do
      [[ -n "${d}" ]] || continue
      printf '\n%s {\n' "${d}"
      printf '    import acme\n'
      for v in "${SELECTED[@]}"; do
        [[ "${DOMAINS[$v]:-}" == "${d}" ]] || continue
        case "${v}" in
          xhttp-tls)
            printf '    @xhttp path %s*\n' "${XHTTP_PATH}"
            printf '    handle @xhttp {\n'
            printf '        reverse_proxy h2c://127.0.0.1:%s\n' "${BACKEND_XHTTP_TLS}"
            printf '    }\n' ;;
          grpc-tls)
            printf '    @grpc path /%s/*\n' "${GRPC_SERVICE}"
            printf '    handle @grpc {\n'
            printf '        reverse_proxy h2c://127.0.0.1:%s\n' "${BACKEND_GRPC_TLS}"
            printf '    }\n' ;;
        esac
      done
      printf '    handle {\n        import site\n    }\n'
      printf '    import errors\n}\n'
    done < <(cert_domains)

    if has_variant hysteria2; then
      cat <<EOF

# Plain HTTP origin consumed only by the Hysteria2 masquerade on loopback.
http://:${PORT_CADDY_PLAIN} {
    import site
    import errors
}
EOF
    fi
  } >"${out}"
  chmod 0644 "${out}"
  log "Caddy: ${out}"
}

# ------------------------------------------------------------ compose files --

render_compose() {
  local edge="${INSTALL_DIR}/docker-compose.edge.yml"
  local node="${INSTALL_DIR}/docker-compose.node.yml"
  local node_env="${PRIVATE_DIR}/node.env"

  cat >"${edge}" <<EOF
name: rw-edge

services:
  haproxy:
    image: ${HAPROXY_IMAGE}
    container_name: rw-edge-haproxy
    network_mode: host
    restart: unless-stopped
    read_only: true
    # The image defaults to USER haproxy, and cap_add grants capabilities to
    # root only: a non-root process receives them in neither the effective nor
    # the ambient set, so binding :443 fails with "Permission denied" and the
    # container restart-loops. The master therefore starts as uid 0 and the
    # config drops every worker back to haproxy:haproxy, which needs SETUID and
    # SETGID. mode=0755 on /run is required for the stats socket; the default
    # tmpfs mode makes that bind fail too.
    user: "0:0"
    command: ["haproxy", "-W", "-db", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE, SETUID, SETGID]
    security_opt: [no-new-privileges:true]
    tmpfs:
      - /run:size=8m,mode=0755
    volumes:
      - ${INSTALL_DIR}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    logging:
      driver: local
      options: {max-size: 10m, max-file: "3"}

  caddy:
    image: ${CADDY_IMAGE}
    container_name: rw-edge-caddy
    network_mode: host
    restart: unless-stopped
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
    volumes:
      - ${INSTALL_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${SITE_DIR}:/srv:ro
      - caddy_data:/data
      - caddy_config:/config
    logging:
      driver: local
      options: {max-size: 10m, max-file: "3"}

volumes:
  caddy_data:
  caddy_config:
EOF

  cat >"${node}" <<EOF
name: rw-node

services:
  remnanode:
    image: ${NODE_IMAGE}
    container_name: rw-node
    network_mode: host
    restart: unless-stopped
    env_file: [${node_env}]
    # Node 2.8 uses fixed nftables table names when NET_ADMIN is present, which
    # collides with any other node sharing this network namespace.
    cap_drop: [NET_ADMIN]
    security_opt: [no-new-privileges:true]
    volumes:
      - ${CERT_DIR}:/etc/rw-certs:ro
    ulimits:
      nofile: {soft: 1048576, hard: 1048576}
    logging:
      driver: local
      options: {max-size: 10m, max-file: "3"}
EOF

  {
    printf 'NODE_PORT=%s\n' "${NODE_PORT}"
    printf 'SECRET_KEY=%s\n' "${NODE_SECRET}"
  } >"${node_env}"
  chmod 0600 "${node_env}"
  chmod 0644 "${edge}" "${node}"
  log "Compose: ${edge}, ${node}"
}

# ============================================================== monitoring ====
#
# Deliberately independent of the Panel. The node ships its own system metrics
# and pushes them out; nothing is read from Remnawave and nothing is stored
# here. If the Panel dies, this keeps reporting — which is the whole point.
#
# Everything is outbound: no port is opened on the node for this.

ask_monitoring() {
  section 'Отправка метрик'

  METRICS_URL="${RW_METRICS_URL:-}"
  METRICS_USER="${RW_METRICS_USER:-}"
  METRICS_PASS="${RW_METRICS_PASS:-}"

  if [[ -n "${METRICS_URL}" ]]; then
    info 'Параметры метрик взяты из переменных окружения.'
    return 0
  fi

  printf '  Ставится три контейнера, все слушают только 127.0.0.1, суммарно ~29 МБ:\n'
  printf '    node-exporter  система: CPU, память, диск, сеть, TCP/UDP, PSI\n'
  printf '    blackbox       зонды пути наружу: ICMP и HTTPS с проверкой\n'
  printf '                   сертификата — меряют путь ИМЕННО этой ноды\n'
  printf '    vmagent        сбор и отправка на ваш приёмник\n\n'
  printf '  Плюс состояние контейнеров через textfile-коллектор: node-exporter\n'
  printf '  про Docker не знает ничего, и упавший Xray выглядит для него\n'
  printf '  здоровой машиной.\n\n'
  printf '  Панель Remnawave не участвует: ничего из неё не читается, при её\n'
  printf '  падении или обновлении сбор продолжается. Входящих портов не\n'
  printf '  открывается, соединение всегда исходящее.\n\n'

  if ! confirm 'Включить отправку метрик'; then
    info 'Метрики отключены.'
    return 0
  fi

  METRICS_URL="$(ask_required 'URL приёма (remoteWrite)')"
  case "${METRICS_URL}" in
    https://*) : ;;
    *) warn 'URL без https: пароль и метрики пойдут открытым текстом.' ;;
  esac
  METRICS_USER="$(ask 'Пользователь basic-auth' 'vmagent')"
  METRICS_PASS="$(ask_secret 'Пароль basic-auth')"
  [[ -n "${METRICS_PASS}" ]] || die 'Пустой пароль для приёма метрик.'
}

# Also true when the stack is on disk but absent from state: a state file
# written by an older build has no METRICS_* lines, and keying off the variable
# alone made `verify` silently skip a deployed, running agent — reporting
# nothing at all rather than reporting a problem.
monitoring_enabled() {
  [[ -n "${METRICS_URL:-}" ]] && return 0
  [[ -f "${INSTALL_DIR}/monitoring/docker-compose.yml" ]]
}

render_monitoring() {
  monitoring_enabled || return 0

  local dir="${INSTALL_DIR}/monitoring"
  mkdir -p "${dir}"

  # No trailing newline: vmagent sends the file's contents verbatim, and a
  # stray \n becomes part of the password.
  printf '%s' "${METRICS_PASS}" >"${dir}/ingest_password"
  chmod 0600 "${dir}/ingest_password"

  cat >"${dir}/scrape.yml" <<EOF
global:
  scrape_interval: 30s
  scrape_timeout: 10s
  external_labels:
    node: '${NODE_CODE}'
    address: '${EDGE_IPV4}'

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']

  # Path quality measured FROM this node. A probe running on the monitoring
  # server would describe that server's path to the internet, not this one's.
  # Targets are deliberately few and boring: a proxy node hammering a long list
  # on a fixed schedule draws a periodic pattern in its own traffic for nothing.
  - job_name: blackbox_icmp
    scrape_interval: 30s
    metrics_path: /probe
    params: {module: [icmp_v4]}
    static_configs:
      - targets: ['1.1.1.1', '8.8.8.8']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115

  - job_name: blackbox_http
    scrape_interval: 60s
    metrics_path: /probe
    params: {module: [http_2xx]}
    static_configs:
      - targets: ['https://www.cloudflare.com/', 'https://www.google.com/']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
EOF
  chmod 0644 "${dir}/scrape.yml"

  cat >"${dir}/blackbox.yml" <<'EOF'
modules:
  icmp_v4:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4

  http_2xx:
    prober: http
    timeout: 8s
    http:
      method: GET
      valid_status_codes: [200]
      preferred_ip_protocol: ip4
      # Verification stays ON deliberately: an untrusted certificate must fail
      # the probe, otherwise a staging or expired one stays invisible — which
      # is exactly how a whole edge can look healthy while no client can use it.
      tls_config:
        insecure_skip_verify: false

  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: ip4
EOF
  chmod 0644 "${dir}/blackbox.yml"

  # node_exporter knows nothing about Docker: to it, a crashed Xray looks like
  # a perfectly healthy machine. cAdvisor would close that gap for 150-200 MB;
  # a cron script writing a textfile closes it for nothing.
  mkdir -p /var/lib/node_exporter/textfile
  cat >/usr/local/bin/rw-docker-textfile.sh <<'EOF'
#!/usr/bin/env bash
set -eu
dir=/var/lib/node_exporter/textfile
mkdir -p "$dir"
tmp="$(mktemp "${dir}/docker.prom.XXXXXX")"
{
  echo '# HELP docker_container_running 1 if the container is running'
  echo '# TYPE docker_container_running gauge'
  echo '# HELP docker_container_restarts_total restarts since creation'
  echo '# TYPE docker_container_restarts_total counter'
  docker ps -a --format '{{.Names}}' | while read -r n; do
    set -- $(docker inspect -f '{{if .State.Running}}1{{else}}0{{end}} {{.RestartCount}}' "$n" 2>/dev/null || echo "0 0")
    printf 'docker_container_running{name="%s"} %s\n' "$n" "$1"
    printf 'docker_container_restarts_total{name="%s"} %s\n' "$n" "$2"
  done
} >"$tmp"
# Atomic swap: without it the exporter occasionally reads a half-written file
# and reports a malformed metric.
chmod 0644 "$tmp"; mv "$tmp" "${dir}/docker.prom"
EOF
  chmod 0755 /usr/local/bin/rw-docker-textfile.sh
  printf '* * * * * root /usr/local/bin/rw-docker-textfile.sh >/dev/null 2>&1\n' \
    >/etc/cron.d/rw-docker-textfile
  chmod 0644 /etc/cron.d/rw-docker-textfile
  /usr/local/bin/rw-docker-textfile.sh || true

  cat >"${dir}/docker-compose.yml" <<EOF
name: rw-monitoring-agent

services:
  node-exporter:
    image: ${NODE_EXPORTER_IMAGE}
    container_name: rw-node-exporter
    # Host namespaces, otherwise the reported network and processes are the
    # container's own and the numbers mean nothing.
    network_mode: host
    pid: host
    restart: unless-stopped
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    mem_limit: 64m
    command:
      # Bound to loopback on purpose: these metrics describe the machine in
      # detail and must not be readable from the internet.
      - '--web.listen-address=127.0.0.1:9100'
      - '--path.rootfs=/host'
      - '--collector.tcpstat'
      - '--collector.textfile.directory=/var/lib/node_exporter/textfile'
      - '--no-collector.wifi'
      - '--no-collector.hwmon'
      - '--no-collector.thermal_zone'
    volumes:
      - /:/host:ro,rslave
      - /var/lib/node_exporter/textfile:/var/lib/node_exporter/textfile:ro
    logging:
      driver: local
      options: {max-size: 5m, max-file: "2"}

  blackbox:
    image: ${BLACKBOX_IMAGE}
    container_name: rw-blackbox
    network_mode: host
    restart: unless-stopped
    read_only: true
    cap_drop: [ALL]
    # ICMP needs raw sockets. Nothing else is granted.
    cap_add: [NET_RAW]
    security_opt: [no-new-privileges:true]
    mem_limit: 64m
    command:
      - '--config.file=/etc/blackbox/blackbox.yml'
      - '--web.listen-address=127.0.0.1:9115'
    volumes:
      - ${dir}/blackbox.yml:/etc/blackbox/blackbox.yml:ro
    logging:
      driver: local
      options: {max-size: 5m, max-file: "2"}

  vmagent:
    image: ${VMAGENT_IMAGE}
    container_name: rw-vmagent
    # Host network so it can reach node-exporter on loopback.
    network_mode: host
    restart: unless-stopped
    security_opt: [no-new-privileges:true]
    mem_limit: 128m
    command:
      - '-promscrape.config=/etc/vmagent/scrape.yml'
      - '-remoteWrite.url=${METRICS_URL}'
      - '-remoteWrite.basicAuth.username=${METRICS_USER}'
      - '-remoteWrite.basicAuth.passwordFile=/etc/vmagent/ingest_password'
      - '-remoteWrite.tmpDataPath=/vmagent-data'
      - '-memory.allowedPercent=60'
      # With host networking vmagent's own port would otherwise listen on every
      # interface of this node.
      - '-httpListenAddr=127.0.0.1:8429'
    volumes:
      - ${dir}/scrape.yml:/etc/vmagent/scrape.yml:ro
      - ${dir}/ingest_password:/etc/vmagent/ingest_password:ro
      - vmagent-data:/vmagent-data
    depends_on: [node-exporter, blackbox]
    logging:
      driver: local
      options: {max-size: 5m, max-file: "2"}

volumes:
  vmagent-data:
EOF
  chmod 0644 "${dir}/docker-compose.yml"
  log "Агент метрик: ${dir}"
}

deploy_monitoring() {
  monitoring_enabled || return 0

  section 'Запуск агента метрик'
  docker pull --quiet "${NODE_EXPORTER_IMAGE}" >/dev/null
  docker pull --quiet "${BLACKBOX_IMAGE}" >/dev/null
  docker pull --quiet "${VMAGENT_IMAGE}" >/dev/null
  docker compose -f "${INSTALL_DIR}/monitoring/docker-compose.yml" up -d --remove-orphans
  sleep 5
  docker ps --filter name=rw-node-exporter --filter name=rw-blackbox --filter name=rw-vmagent \
    --format '  {{.Names}}  {{.Status}}'
}

verify_monitoring() {
  monitoring_enabled || return 0

  local scraped sent
  if ! curl -fsS --max-time 5 http://127.0.0.1:9100/metrics >/dev/null 2>&1; then
    warn 'node-exporter не отвечает на 127.0.0.1:9100.'
    return 0
  fi
  log 'node-exporter отвечает.'

  # Give vmagent one scrape interval before judging it.
  sleep 20
  # $NF, not $2: VictoriaMetrics prints labels separated by ", " with a space,
  # so on a multi-label metric $2 is the second label rather than the value and
  # this check reported zero deliveries on a perfectly healthy agent.
  scraped="$(curl -fsS --max-time 5 http://127.0.0.1:8429/metrics 2>/dev/null \
    | awk '/^vm_promscrape_scrapes_total/ {s+=$NF} END {printf "%d", s+0}')"
  sent="$(curl -fsS --max-time 5 http://127.0.0.1:8429/metrics 2>/dev/null \
    | awk '/^vmagent_remotewrite_requests_total.*status_code="2/ {s+=$NF} END {printf "%d", s+0}')"

  if curl -fsS --max-time 10 'http://127.0.0.1:9115/probe?module=icmp_v4&target=1.1.1.1' 2>/dev/null \
     | grep -q '^probe_success 1'; then
    log 'Зонды пути наружу работают.'
  else
    warn 'blackbox не отвечает — сетевые зонды собираться не будут.'
  fi

  (( scraped > 0 )) && log "Скрейпов выполнено: ${scraped}." \
    || warn 'vmagent пока ничего не собрал.'

  if (( sent > 0 )); then
    log "Метрики уходят на приёмник: успешных запросов ${sent}."
  else
    warn 'Ни одной успешной отправки. Проверьте URL и пароль:'
    warn '  docker logs rw-vmagent 2>&1 | tail -20'
    warn '  401 — неверный пароль, 404 — неверный путь, connection refused — недоступен приёмник.'
  fi
}

# ============================================================ system tuning ===

tune_kernel() {
  section 'Тюнинг ядра'

  local f='/etc/sysctl.d/99-rw-edge.conf'
  cat >"${f}" <<'EOF'
# Managed by rw-edge installer. Delete this file and reboot to revert.

# BBR over fq: fq is what lets BBR pace, without it the algorithm degrades.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Accept queues. The default 4096 backlog drops connections during bursts.
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384

# QUIC and Hysteria2 are userspace over UDP: the socket buffers are the
# throughput ceiling, and the defaults are far too small for a 1 Gbit link.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# Many short-lived TLS connections.
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 10240 65535

# Conntrack headroom; a busy edge exhausts the default table quickly.
net.netfilter.nf_conntrack_max = 262144

fs.file-max = 1048576
EOF

  # nf_conntrack_max only exists once the module is loaded.
  modprobe nf_conntrack 2>/dev/null || true
  if sysctl --system >/dev/null 2>&1; then
    log 'sysctl применён.'
  else
    warn 'Часть sysctl не применилась — вероятно, ядро без нужных модулей. Не критично.'
  fi

  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  if [[ "${cc}" == 'bbr' ]]; then
    log 'BBR активен.'
  else
    warn "Congestion control сейчас '${cc}', не bbr. Возможно, ядру нужен модуль tcp_bbr."
  fi

  local lim='/etc/security/limits.d/99-rw-edge.conf'
  cat >"${lim}" <<'EOF'
*  soft  nofile  1048576
*  hard  nofile  1048576
EOF
  log 'Лимиты файловых дескрипторов подняты.'
}

# ------------------------------------------------------------------ docker ---

install_docker() {
  section 'Docker'

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker уже стоит: $(docker --version | head -1)"
    return 0
  fi

  info 'Ставлю Docker из официального репозитория.'
  install -m 0755 -d /etc/apt/keyrings
  local id_lower
  id_lower="$(. /etc/os-release && printf '%s' "${ID}")"
  curl -fsSL "https://download.docker.com/linux/${id_lower}/gpg" \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$(dpkg --print-architecture)" "${id_lower}" \
    "$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")" \
    >/etc/apt/sources.list.d/docker.list
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true
  log "Docker поставлен: $(docker --version | head -1)"
}

pull_images() {
  section 'Образы'
  local img
  for img in "${NODE_IMAGE}" "${CADDY_IMAGE}" "${HAPROXY_IMAGE}"; do
    info "pull ${img%%@*}"
    docker pull --quiet "${img}" >/dev/null
  done
  log 'Все три образа получены по digest.'
}

# ---------------------------------------------------------------- firewall ---

setup_firewall() {
  section 'Firewall'

  local ssh_port
  ssh_port="$(ss -lntpH 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]}' | head -1)"
  [[ "${ssh_port}" =~ ^[0-9]+$ ]] || ssh_port=22
  info "SSH определён на порту ${ssh_port}."

  # Deliberately no `ufw --force reset`: it silently deletes every rule already
  # on the host, including ones this installer knows nothing about. Rules are
  # added instead, and ufw itself is idempotent about duplicates.
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null
  ufw allow 443/tcp comment 'rw-edge user plane' >/dev/null

  if has_variant hysteria2; then
    ufw allow 443/udp comment 'rw-edge Hysteria2' >/dev/null
    log 'Открыт UDP/443 для Hysteria2.'
  fi

  ufw allow from "${PANEL_IPV4}" to any port "${NODE_PORT}" proto tcp \
    comment 'Remnawave Node API' >/dev/null
  log "Node API ${NODE_PORT}/tcp открыт только для ${PANEL_IPV4}."

  if ufw status 2>/dev/null | head -1 | grep -q inactive; then
    printf '\n  UFW сейчас выключен. Включение задействует политику default-deny.\n'
    printf '  Правило для SSH на порту %s уже добавлено.\n\n' "${ssh_port}"
    if [[ "${RW_ENABLE_UFW:-}" == '1' ]] || confirm_typed 'Включить UFW' 'ENABLE'; then
      ufw --force enable >/dev/null
      log 'UFW включён.'
    else
      warn 'UFW оставлен выключенным. Правила записаны и применятся при включении.'
    fi
  else
    ufw reload >/dev/null 2>&1 || true
    log 'UFW уже был включён, правила перезагружены.'
  fi
}

# ------------------------------------------------------------ certificates ---

install_cert_sync() {
  # tcp-tls and hysteria2 need certificate files inside the node container.
  # Caddy owns ACME; this copies what it issued into a stable path.
  has_variant tcp-tls || has_variant hysteria2 || return 0

  section 'Синхронизация сертификатов'

  mkdir -p "${CERT_DIR}"
  chmod 0755 "${CERT_DIR}"

  local sync="${INSTALL_DIR}/sync-certs.sh"
  cat >"${sync}" <<'EOF'
#!/usr/bin/env bash
# Copy certificates issued by Caddy into a path the node container can read.
# Idempotent; safe to run from cron every few minutes.
set -Eeuo pipefail
umask 022

CERT_DIR="${1:?usage: sync-certs.sh <cert-dir> <domain>...}"
shift
VOL="$(docker volume inspect rw-edge_caddy_data --format '{{ .Mountpoint }}' 2>/dev/null || true)"
[[ -n "${VOL}" ]] || { echo "caddy data volume not found" >&2; exit 1; }

changed=0
for domain in "$@"; do
  # Glob over the issuer directory so a change of CA does not break this.
  src_crt="$(find "${VOL}/caddy/certificates" -type f -name "${domain}.crt" 2>/dev/null | head -1)"
  src_key="$(find "${VOL}/caddy/certificates" -type f -name "${domain}.key" 2>/dev/null | head -1)"
  [[ -n "${src_crt}" && -n "${src_key}" ]] || { echo "no certificate yet for ${domain}" >&2; continue; }

  dst="${CERT_DIR}/${domain}"
  mkdir -p "${dst}"
  if ! cmp -s "${src_crt}" "${dst}/fullchain.pem"; then
    install -m 0644 "${src_crt}" "${dst}/fullchain.pem"
    install -m 0644 "${src_key}" "${dst}/privkey.pem"
    changed=1
    echo "updated ${domain}"
  fi
done

# Xray does NOT pick up a replaced certificate file on its own, despite
# oneTimeLoading:false — verified on 26.6.27: after the files on disk were
# swapped it kept serving the previous certificate until the process restarted.
# Without this restart a renewal 60 days from now would leave tcp-tls and
# hysteria2 presenting an expired certificate, and nothing would report it.
if (( changed == 1 )); then
  echo "certificates changed, restarting node so Xray picks them up"
  docker restart rw-node >/dev/null 2>&1 || echo "could not restart rw-node" >&2
fi
exit 0
EOF
  chmod 0755 "${sync}"

  local doms=() d
  while read -r d; do
    [[ -n "${d}" ]] || continue
    for v in "${SELECTED[@]}"; do
      if [[ "${v}" == 'tcp-tls' || "${v}" == 'hysteria2' ]] && [[ "${DOMAINS[$v]:-}" == "${d}" ]]; then
        doms+=("${d}")
      fi
    done
  done < <(cert_domains)

  # dedupe
  local uniq=() x seen
  for d in "${doms[@]:-}"; do
    seen=0
    for x in "${uniq[@]:-}"; do [[ "${x}" == "${d}" ]] && seen=1; done
    (( seen == 0 )) && uniq+=("${d}")
  done
  CERT_SYNC_DOMAINS="${uniq[*]}"

  printf '*/10 * * * * root %s %s %s >/dev/null 2>&1\n' \
    "${sync}" "${CERT_DIR}" "${CERT_SYNC_DOMAINS}" >/etc/cron.d/rw-edge-certs
  chmod 0644 /etc/cron.d/rw-edge-certs
  log "Хук синхронизации поставлен для: ${CERT_SYNC_DOMAINS}"
}

wait_for_certs() {
  has_variant tcp-tls || has_variant hysteria2 || return 0

  section 'Ожидание сертификатов'

  local deadline=$(( SECONDS + 180 )) d ok
  while (( SECONDS < deadline )); do
    "${INSTALL_DIR}/sync-certs.sh" "${CERT_DIR}" ${CERT_SYNC_DOMAINS} >/dev/null 2>&1 || true
    ok=1
    for d in ${CERT_SYNC_DOMAINS}; do
      [[ -s "${CERT_DIR}/${d}/fullchain.pem" ]] || ok=0
    done
    (( ok == 1 )) && { log 'Сертификаты на месте.'; return 0; }
    sleep 10
    info 'Caddy ещё выпускает сертификат...'
  done

  die 'Сертификаты так и не появились за 3 минуты. Смотрите: docker logs rw-edge-caddy'
}

# ------------------------------------------------------------------ deploy ---

deploy_edge() {
  section 'Запуск edge'
  docker compose -f "${INSTALL_DIR}/docker-compose.edge.yml" up -d --remove-orphans
  sleep 3
  docker ps --filter name=rw-edge --format '  {{.Names}}  {{.Status}}'
}

deploy_node() {
  section 'Запуск ноды'
  docker compose -f "${INSTALL_DIR}/docker-compose.node.yml" up -d --remove-orphans
  sleep 5
  docker ps --filter name=rw-node --format '  {{.Names}}  {{.Status}}'
}

# ========================================================= client template ====

render_client_template() {
  local out="${PRIVATE_DIR}/xray-json-template.json"
  local n=0 v sel=()

  # Слот на КАЖДЫЙ хост, включая Hysteria2: пароль подставляет Panel при
  # инжекте, руками его в шаблон вписывать по-прежнему нельзя.
  for v in "${SELECTED[@]}"; do
    n=$((n + 1))
    sel+=("__HOST_UUID_${n}__")
  done
  (( n > 0 )) || return 0

  local values
  values="$(printf '%s\n' "${sel[@]}" | jq -R . | jq -s .)"

  jq -n --argjson values "${values}" '{
    remnawave: {
      injectHosts: [{
        selector: {type: "uuids", values: $values},
        selectFrom: "HIDDEN",
        tagPrefix: "proxy"
      }]
    },
    log: {loglevel: "warning"},
    dns: {
      queryStrategy: "UseIPv4",
      servers: [
        {address: "1.1.1.1", domains: ["geosite:category-ru"], skipFallback: true},
        "1.1.1.1",
        "1.0.0.1"
      ]
    },
    inbounds: [
      {tag: "socks", listen: "127.0.0.1", port: 10808, protocol: "socks",
       settings: {auth: "noauth", udp: true},
       sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}},
      {tag: "http", listen: "127.0.0.1", port: 10809, protocol: "http",
       settings: {allowTransparent: false},
       sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}}
    ],
    burstObservatory: {
      subjectSelector: ["proxy"],
      pingConfig: {destination: "https://8.8.8.8/generate_204", connectivity: "",
                   interval: "1m", sampling: 2, timeout: "5s", httpMethod: "HEAD"}
    },
    routing: {
      domainMatcher: "hybrid",
      domainStrategy: "IPIfNonMatch",
      balancers: [{tag: "AUTO", selector: ["proxy"], fallbackTag: "proxy",
                   strategy: {type: "leastPing"}}],
      rules: [
        {type: "field", protocol: ["bittorrent"], outboundTag: "direct"},
        {type: "field", network: "tcp,udp", port: "27015-27059,3478,4379-4380",
         outboundTag: "direct"},
        {type: "field", domain: [
          "geosite:category-ru", "geosite:steam", "geosite:twitch",
          "geosite:apple", "geosite:xiaomi", "geosite:huawei",
          "geosite:category-android-app-download",
          "domain:vk.com","domain:vk.ru","domain:userapi.com","domain:vk-cdn.net",
          "domain:vkuser.net","domain:vkuservideo.net","domain:vkvideo.ru",
          "domain:ok.ru","domain:okcdn.ru","domain:mycdn.me",
          "domain:mail.ru","domain:dzen.ru","domain:dzeninfra.ru",
          "domain:yandex.ru","domain:yandex.net","domain:yastatic.net",
          "domain:sberbank.ru","domain:sber.ru","domain:tbank.ru","domain:tinkoff.ru",
          "domain:ozon.ru","domain:o3.ru","domain:avito.ru","domain:avito.st",
          "domain:wildberries.ru","domain:wbbasket.ru",
          "domain:gosuslugi.ru","domain:2gis.ru","domain:max.ru","domain:oneme.ru"
        ], outboundTag: "direct"},
        {type: "field", ip: ["geoip:ru", "geoip:private"], outboundTag: "direct"},
        {type: "field", network: "tcp,udp", balancerTag: "AUTO"}
      ]
    },
    outbounds: [
      {tag: "direct", protocol: "freedom", settings: {domainStrategy: "UseIPv4"}},
      {tag: "block", protocol: "blackhole"}
    ]
  }' >"${out}"
  chmod 0600 "${out}"
  log "Клиентский шаблон: ${out} (${n} плейсхолдеров под UUID хостов)"
}

# ================================================================ validation ==

validate_artifacts() {
  section 'Валидация сгенерированного'

  jq empty "${PRIVATE_DIR}/config-profile.json" \
    || die 'Серверный профиль — невалидный JSON.'

  # The real pinned Xray, not a schema guess. Certificates referenced by
  # tcp-tls/hysteria2 must exist, so validation runs after they are synced.
  local mounts=()
  [[ -d "${CERT_DIR}" ]] && mounts=(-v "${CERT_DIR}:/etc/rw-certs:ro")
  docker run --rm --pull never --network none --cap-drop ALL --read-only \
    "${mounts[@]}" \
    -v "${PRIVATE_DIR}/config-profile.json:/etc/xray/config.json:ro" \
    --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
    run -test -config /etc/xray/config.json >/dev/null \
    || die 'Xray отверг серверный профиль.'
  log 'Серверный профиль принят настоящим Xray.'

  docker run --rm --pull never --network none --cap-drop ALL --read-only \
    -v "${INSTALL_DIR}/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    "${HAPROXY_IMAGE}" haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null \
    || die 'HAProxy отверг конфиг.'
  log 'HAProxy конфиг валиден.'

  # The Caddy binary carries file capabilities; dropping ALL makes exec fail
  # with "operation not permitted" before the config is even read.
  local caddy_out
  if ! caddy_out="$(docker run --rm --pull never --network none \
      --cap-drop ALL --cap-add NET_BIND_SERVICE --read-only \
      --tmpfs /data:rw,size=8m --tmpfs /config:rw,size=2m --tmpfs /run:rw,size=1m \
      -v "${INSTALL_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" \
      -v "${SITE_DIR}:/srv:ro" \
      "${CADDY_IMAGE}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
    printf '%s\n' "${caddy_out}" >&2
    die 'Caddy отверг Caddyfile.'
  fi
  log 'Caddyfile валиден.'

  if [[ -f "${PRIVATE_DIR}/xray-json-template.json" ]]; then
    # Model what the Panel emits: strip the directive, inject one real outbound.
    local tmp; tmp="$(mktemp)"
    jq 'del(.remnawave) | .outbounds = [{
          tag: "proxy", protocol: "vless",
          settings: {vnext: [{address: "127.0.0.1", port: 443, users: [{id: "00000000-0000-0000-0000-000000000000", encryption: "none"}]}]},
          streamSettings: {network: "raw", security: "none"}
        }] + .outbounds' "${PRIVATE_DIR}/xray-json-template.json" >"${tmp}"
    docker run --rm --pull never --network none --cap-drop ALL --read-only \
      -v "${tmp}:/etc/xray/config.json:ro" \
      --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" \
      run -test -config /etc/xray/config.json >/dev/null \
      || { rm -f "${tmp}"; die 'Клиентский шаблон отвергнут Xray.'; }
    rm -f "${tmp}"
    log 'Клиентский шаблон принят Xray после моделирования инъекции.'
  fi
}

# =============================================================== runtime ======

# A staging certificate makes every TLS-terminating transport unusable while
# leaving REALITY perfectly healthy, so a run can look entirely green and still
# be broken for most clients. Say it loudly rather than let it pass.
check_cert_trust() {
  local d issuer staging=0
  while read -r d; do
    [[ -n "${d}" ]] || continue
    issuer="$(echo | timeout 10 openssl s_client -connect "${d}:443" -servername "${d}" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null || true)"
    [[ "${issuer}" == *STAGING* ]] && { staging=1; warn "${d}: сертификат STAGING, клиенты его не примут."; }
  done < <(cert_domains)

  if (( staging == 1 )); then
    warn ''
    warn 'ВНИМАНИЕ: сертификаты тестовые (ACME staging).'
    warn 'REALITY будет работать — он сертификат не использует. Всё остальное'
    warn '(TLS, XHTTP, gRPC, Hysteria2) клиенты отвергнут по недоверию.'
    warn 'Лечится так:'
    warn "  sed -i '/acme-staging-v02/d' ${INSTALL_DIR}/Caddyfile"
    warn '  docker restart rw-edge-caddy       # admin API выключен, reload не сработает'
    warn "  ${INSTALL_DIR}/sync-certs.sh ${CERT_DIR} <домены tcp-tls/hysteria2>"
    warn '  docker restart rw-node             # Xray держит старый сертификат в памяти'
    return 1
  fi
  log 'Сертификаты доверенные.'
}

domain_variant() {
  local dom="$1" v
  for v in "${SELECTED[@]}"; do
    [[ "${DOMAINS[$v]:-}" == "${dom}" ]] && { printf '%s' "${v}"; return 0; }
  done
  return 1
}

verify_runtime() {
  section 'Проверка вживую'

  local p
  for p in 443 "${PORT_CADDY_TLS}"; do
    port_free "${p}" && die "Порт ${p} не слушается — что-то не поднялось."
  done

  check_cert_trust || true
  log 'TCP/443 и Caddy слушают.'

  local v backend
  for v in "${SELECTED[@]}"; do
    [[ "${v}" == 'hysteria2' ]] && continue
    backend="$(variant_backend "${v}")"
    if port_free "${backend}"; then
      warn "Backend ${backend} (${v}) не слушает. Панель ещё не отдала профиль — это ожидаемо до шага с Config Profile."
    else
      log "Backend ${backend} (${v}) поднят."
    fi
  done

  local d code
  while read -r d; do
    [[ -n "${d}" ]] || continue
    # Staging certificates are untrusted by design, so verification of the
    # chain has to be skipped or every check below reports a false failure.
    local ins=(); [[ "${RW_ACME_STAGING:-}" == '1' ]] && ins=(-k)

    # On a tcp-tls domain Xray terminates TLS itself and VLESS sits behind it,
    # so there is no HTTP server to answer and a 200 is impossible by design.
    # Asking for one here produced a warning blaming the Panel for a backend
    # that was in fact up and healthy.
    local own; own="$(domain_variant "${d}" || true)"
    if [[ "${own}" == 'tcp-tls' ]]; then
      if echo | timeout 10 openssl s_client -connect "${d}:443" \
           -servername "${d}" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
        log "${d}: TLS отвечает. HTTP тут не будет — за ним VLESS, так и задумано."
      else
        warn "${d}: TLS не отвечает — backend ${BACKEND_TCP_TLS} не поднят панелью."
      fi
      continue
    fi

    code="$(curl -sS "${ins[@]}" -o /dev/null -w '%{http_code}' --max-time 15 \
      --resolve "${d}:443:${EDGE_IPV4}" "https://${d}/" 2>/dev/null || true)"
    if [[ "${code}" == '200' ]]; then
      log "https://${d}/ → 200, сайт прикрытия отдаётся."
    else
      if [[ "${code}" == '000' ]] && [[ -d "$(docker volume inspect rw-edge_caddy_data --format '{{.Mountpoint}}' 2>/dev/null)/caddy/certificates" ]]; then
        warn "https://${d}/ → нет ответа. Сертификат выпущен, значит SNI этого домена ведёт в Xray-бэкенд, который ещё не поднят панелью. Станет доступен после шага с Config Profile."
      else
        warn "https://${d}/ → ${code}. Сертификат, вероятно, ещё не выпущен."
      fi
    fi
    code="$(curl -sS "${ins[@]}" -o /dev/null -w '%{http_code}' --max-time 15 \
      --resolve "${d}:443:${EDGE_IPV4}" "https://${d}/nope-$(rand_hex 4)" 2>/dev/null || true)"
    [[ "${code}" == '404' ]] && log "404 на ${d} настоящий." \
      || warn "На несуществующий путь ${d} ответил ${code}, ожидался 404."
  done < <(cert_domains)

  if has_variant hysteria2; then
    # $4, not $5: in `ss -lnu` output the local address is the fourth column
    # and the fifth is the peer. Reading $5 reported "not listening" while
    # Hysteria2 was bound and serving.
    if ss -lnuH 2>/dev/null | awk '{print $4}' | grep -qE '[:.]443$'; then
      log 'UDP/443 слушается — Hysteria2 поднялся.'
    else
      warn 'UDP/443 не слушается. Профиль ещё не применён панелью.'
    fi
    warn 'Masquerade проверяется только настоящим HTTP/3 клиентом. Проверьте вручную: curl --http3 https://<домен>/ с машины, где curl собран с HTTP/3.'
  fi
}

# ========================================================== panel guide =======

print_instructions() {
  local guide="${PRIVATE_DIR}/PANEL-STEPS.txt"
  {
    printf '================================================================\n'
    printf ' REMNAWAVE — что вставить в панель\n'
    printf ' Сгенерировано %s установщиком %s\n' "$(date -Is)" "${SCRIPT_VERSION}"
    printf '================================================================\n\n'

    printf 'ШАГ 1. CONFIG PROFILE\n'
    printf '  Config Profiles -> Create -> вставить целиком:\n'
    printf '    %s\n\n' "${PRIVATE_DIR}/config-profile.json"
    printf '  Ожидаемые inbound-теги:\n'
    local v
    for v in "${SELECTED[@]}"; do printf '    - %s\n' "$(variant_tag "${v}")"; done
    printf '\n'

    printf 'ШАГ 2. NODE\n'
    printf '  Address ............ %s\n' "${EDGE_IPV4}"
    printf '  Port ............... %s\n' "${NODE_PORT}"
    printf '  Config Profile ..... созданный на шаге 1\n'
    printf '  Active Inbounds .... все перечисленные выше\n'
    printf '  SECRET_KEY ......... уже прописан на сервере, из панели копировать не нужно\n'
    printf '  Дождитесь статуса connected: до этого backends не слушают.\n\n'

    printf 'ШАГ 3. HOSTS\n'
    printf '  Создайте по одному Host на каждый транспорт.\n\n'
    printf '  ЧЕГО В ФОРМЕ HOST НЕТ И ИСКАТЬ НЕ НАДО:\n'
    printf '    Public Key и Short ID — Panel выводит их из realitySettings\n'
    printf '      конфиг-профиля сама, отдельных полей для них нет.\n'
    printf '    Flow — клиенты (Happ, INCY) подставляют его сами; в профиле он\n'
    printf '      уже задан на уровне инбаунда как xtls-rprx-vision.\n\n'
    printf '  HIDDEN — включить у ВСЕХ хостов ниже\n\n'
    printf '    Все физические Hosts помечаются Hidden. Видимым остаётся только\n'
    printf '    виртуальный AUTO из шага 5.\n\n'
    printf '    Шаблон забирает их через selectFrom: "HIDDEN", поэтому спрятанный\n'
    printf '    хост не исчезает, а попадает внутрь AUTO вместе с правилами\n'
    printf '    маршрутизации.\n\n'
    printf '    Смысл в том, что взять транспорт в обход шаблона становится\n'
    printf '    неоткуда. Видимый хост без шаблона отдаёт клиенту сервер без\n'
    printf '    RU-direct: российский трафик пойдёт через заграницу, у клиента\n'
    printf '    отвалятся банки и госуслуги, а вы заплатите за этот трафик.\n\n'
    printf '    Exclude formats при этой схеме трогать не нужно.\n\n'
    printf '    ПРОВЕРКА: клиент должен увидеть РОВНО ОДНУ запись.\n'
    printf '    Если записей больше — какой-то хост остался видимым.\n'
    printf '    Если ни одной — спрятали заодно и виртуальный AUTO.\n\n'

    local i=0
    for v in "${SELECTED[@]}"; do
      i=$((i + 1))
      printf '  --- Host %d: %s ---\n' "${i}" "${v}"
      printf '    Remark ............. %s\n' "$(variant_tag "${v}")"
      printf '    Inbound ............ %s\n' "$(variant_tag "${v}")"
      printf '    Address ............ %s   (IP, не домен)\n' "${EDGE_IPV4}"
      printf '    Port ............... 443\n'
      case "${v}" in
        reality-tcp-steal)
          printf '    SNI ................ %s\n' "${DOMAINS[$v]}"
          printf '    Security Layer ..... Inbound'\''s default\n'
          printf '    Fingerprint ........ chrome\n'
          printf '    ALPN ............... оставить ПУСТЫМ\n'
          printf '                         REALITY берёт ALPN из fingerprint клиента;\n'
          printf '                         фиксированное значение ломает отпечаток.\n' ;;
        reality-tcp-borrow)
          printf '    SNI ................ %s   (донор, не наш домен)\n' "${BORROW_SNI}"
          printf '    Security Layer ..... Inbound'\''s default\n'
          printf '    Fingerprint ........ chrome\n'
          printf '    ALPN ............... оставить ПУСТЫМ\n' ;;
        reality-xhttp-steal)
          printf '    SNI ................ %s\n' "${DOMAINS[$v]}"
          printf '    Path ............... %s\n' "${XHTTP_PATH}"
          printf '    Security Layer ..... Inbound'\''s default\n'
          printf '    Fingerprint ........ chrome\n'
          printf '    ALPN ............... оставить ПУСТЫМ\n' ;;
        xhttp-tls)
          printf '    SNI / Host ......... %s\n' "${DOMAINS[$v]}"
          printf '    Path ............... %s\n' "${XHTTP_PATH}"
          printf '    ALPN ............... h2\n'
          printf '    Security Layer ..... TLS\n'
          printf '    Fingerprint ........ chrome\n'
          ;;
        grpc-tls)
          printf '    SNI / Host ......... %s\n' "${DOMAINS[$v]}"
          printf '    serviceName ........ %s\n' "${GRPC_SERVICE}"
          printf '    ALPN ............... h2\n'
          printf '    Security Layer ..... TLS\n'
          ;;
        tcp-tls)
          printf '    SNI / Host ......... %s\n' "${DOMAINS[$v]}"
          printf '    ALPN ............... h2, http/1.1   (как в tlsSettings профиля)\n'
          printf '    Security Layer ..... TLS\n'
          printf '    Fingerprint ........ chrome\n'
          ;;
        hysteria2)
          printf '    SNI ................ %s\n' "${DOMAINS[$v]}"
          printf '    Port ............... 443/udp\n'
          printf '    ALPN ............... h3\n'
          printf '    Security Layer ..... TLS (сертификат Let'\''s Encrypt, не self-signed)\n'
          printf '    Примечание ......... см. блок про Hysteria2 ниже\n' ;;
      esac
      printf '    Hidden ............. ДА\n\n'
    done

    if [[ -f "${PRIVATE_DIR}/xray-json-template.json" ]]; then
      printf 'ШАГ 4. XRAY JSON TEMPLATE\n'
      printf '  Subscription -> Templates -> Xray JSON -> создать и вставить:\n'
      printf '    %s\n\n' "${PRIVATE_DIR}/xray-json-template.json"
      printf '  Перед вставкой замените плейсхолдеры на UUID созданных Hosts:\n'
      local n=0
      for v in "${SELECTED[@]}"; do
        n=$((n + 1))
        printf '    __HOST_UUID_%d__  ->  UUID хоста %s\n' "${n}" "$(variant_tag "${v}")"
      done
      printf '\n  UUID берётся из карточки Host, это не UUID пользователя.\n'
      printf '  Шаблон уже содержит балансировщик leastPing по префиксу proxy,\n'
      printf '  сплит RU-direct и блок bittorrent.\n\n'

      printf 'ШАГ 5. VIRTUAL HOST ДЛЯ ШАБЛОНА\n'
      printf '  Создайте ещё один Host:\n'
      printf '    Remark ............. %s_AUTO\n' "${NODE_CODE}"
      printf '    Inbound ............ %s\n' "$(variant_tag "${SELECTED[0]}")"
      printf '    Address / Port ..... %s / 443\n' "${EDGE_IPV4}"
      printf '    Xray JSON Template . созданный на шаге 4\n'
      printf '    Hidden ............. НЕТ — единственный видимый хост\n\n'
      printf '  Все физические Hosts спрятаны на шаге 3, шаблон забирает их\n'
      printf '  через selectFrom: "HIDDEN". Клиент видит одну запись, внутри\n'
      printf '  неё все транспорты и правила RU-direct.\n\n'
    fi

    printf 'ШАГ 6. SUBSCRIPTION SETTINGS\n'
    printf '  Использовать JSON в базовой подписке .... включить\n\n'

    if has_variant hysteria2; then
      printf 'HYSTERIA2 И КЛИЕНТСКИЙ ШАБЛОН\n'
      printf '  В сгенерированный шаблон Hysteria2 не включена — и вот почему.\n\n'
      printf '  Исходящий hysteria в ядре ЕСТЬ (проверено на 26.6.27), форма такая:\n'
      printf '    "protocol": "hysteria",\n'
      printf '    "settings": {"version": 2, "address": "<домен>", "port": 443},\n'
      printf '    "streamSettings": {"network": "hysteria", "security": "tls",\n'
      printf '      "finalmask": {"quicParams": {"congestion": "bbr"}},\n'
      printf '      "tlsSettings": {"serverName": "<домен>", "alpn": ["h3"]},\n'
      printf '      "hysteriaSettings": {"version": 2, "auth": "ПАРОЛЬ"}}\n\n'
      printf '  Загвоздка в auth: это пароль КОНКРЕТНОГО юзера. Вписать его в\n'
      printf '  шаблон нельзя — все клиенты сядут на одну учётку, и рассыплется\n'
      printf '  поюзерный учёт трафика, HWID и отзыв доступа. Пароль обязан\n'
      printf '  приезжать от Panel через injectHosts.\n\n'
      printf '  Слот под её UUID в шаблоне уже есть, прятать её нужно так же,\n'
      printf '  как остальные. Инжектит ли Panel hysteria — видно на ноде:\n\n'
      printf '    ss -unH state established %s( sport = :443 )%s | wc -l\n\n' "'" "'"
      printf '  Больше нуля при подключённом клиенте — инжектит, транспорт\n'
      printf '  работает внутри AUTO наравне с остальными. Ноль — не инжектит,\n'
      printf '  UDP/443 просто не используется. Пароль в шаблон руками НЕ\n'
      printf '  вписывать: он поюзерный, одна учётка на всех обрушит учёт\n'
      printf '  трафика, HWID и отзыв доступа.\n\n'
    fi

    if monitoring_enabled; then
      printf 'МОНИТОРИНГ — что сделать на сервере с Grafana\n'
      printf '  Правила алертов трогать НЕ нужно. Они написаны через by(node)\n'
      printf '  с оконным детектором пропажи, поэтому нода %s покрывается\n' "${NODE_CODE}"
      printf '  автоматически, как только приедут первые метрики.\n\n'
      printf '  Проверить в Explore (должна появиться за минуту):\n'
      printf '    up{job="node"}\n\n'
      printf '  Ручной шаг ровно один — внешняя проба этой ноды с точки\n'
      printf '  наблюдения. Она отвечает на вопрос "видят ли клиенты" и сама\n'
      printf '  не появится: нода умеет рассказать о себе изнутри, но не может\n'
      printf '  проверить, видна ли она из интернета.\n\n'
      printf '  Зайдите на сервер с Grafana и откройте scrape-конфиг vmagent\n'
      printf '  (обычно /opt/rw-monitoring/vmagent/scrape.yml).\n\n'
      printf '  ЕСЛИ джоб blackbox-tcp там УЖЕ ЕСТЬ — а он есть, как только\n'
      printf '  заведена хотя бы одна нода — допишите в его static_configs\n'
      printf '  ТОЛЬКО эти две строки, рядом с существующими целями:\n\n'
      printf "        - targets: ['%s:443']\n" "${EDGE_IPV4}"
      printf "          labels: { vantage: 'billing', target: '%s' }\n\n" "${NODE_CODE}"
      printf '  Целиком блок ниже вставлять НЕЛЬЗЯ: получится второй job_name\n'
      printf '  с тем же именем, а vmagent такой конфиг отвергает целиком —\n'
      printf '  "duplicate job_name in scrape_configs". Перестанут собираться\n'
      printf '  все метрики, а не только эта проба.\n\n'
      printf '  ЕСЛИ джоба blackbox-tcp ещё нет (самая первая нода) — тогда\n'
      printf '  вставьте блок целиком:\n\n'
      printf '    - job_name: blackbox-tcp\n'
      printf '      metrics_path: /probe\n'
      printf '      params: {module: [tcp_connect]}\n'
      printf '      static_configs:\n'
      printf "        - targets: ['%s:443']\n" "${EDGE_IPV4}"
      printf "          labels: { vantage: 'billing', target: '%s' }\n" "${NODE_CODE}"
      printf '      relabel_configs:\n'
      printf '        - source_labels: [__address__]\n'
      printf '          target_label: __param_target\n'
      printf '        - source_labels: [__param_target]\n'
      printf '          target_label: instance\n'
      printf '        - target_label: __address__\n'
      printf '          replacement: <хост:порт вашего blackbox>\n\n'
      printf '  Метка vantage вместо node — намеренно: под node попадают только\n'
      printf '  метрики, которые нода шлёт сама. Иначе внешняя проба маскирует\n'
      printf '  пропажу ноды (у неё остаётся свежий ряд с той же меткой) и\n'
      printf '  попадает под подавление вместе с нодовыми правилами.\n\n'
      printf '  Перечитать конфиг (сам он этого не делает):\n'
      printf '    docker kill -s HUP <контейнер vmagent на сервере мониторинга>\n\n'
      printf '  Через 2 минуты проверить:\n'
      printf '    probe_success{target="%s"}   → 1\n\n' "${NODE_CODE}"
      printf '  Дашборды править не нужно: переменная node подхватит ноду сама.\n\n'
    fi

    printf 'ПРОВЕРКА ПОСЛЕ ВСЕГО\n'
    printf '  На сервере:\n'
    printf '    ss -lnt | grep -E "18443|18444|18445|18446|18447"\n'
    if has_variant hysteria2; then
      printf '    ss -lnu | grep 443\n'
    fi
    printf '    docker logs --tail 30 rw-node\n'
    local d
    while read -r d; do
      [[ -n "${d}" ]] || continue
      printf '    curl -sI https://%s/ | head -1     # ждём 200\n' "${d}"
    done < <(cert_domains)
    printf '\n  С клиента: подключиться и открыть любой заблокированный сайт.\n\n'

    printf 'ФАЙЛЫ\n'
    printf '  Серверный профиль ... %s\n' "${PRIVATE_DIR}/config-profile.json"
    [[ -f "${PRIVATE_DIR}/xray-json-template.json" ]] && \
      printf '  Клиентский шаблон ... %s\n' "${PRIVATE_DIR}/xray-json-template.json"
    printf '  Состояние ........... %s\n' "${STATE_FILE}"
    printf '  Эта инструкция ...... %s\n' "${guide}"
  } | tee "${guide}"
  chmod 0600 "${guide}"
}

# ================================================================== rollback ==

do_rollback() {
  section 'Откат'

  # Раньше эта команда сносила всё сразу, без единого вопроса: один вызов
  # `rw-edge-install.sh rollback` гасил edge, ноду и агент метрик за секунду.
  # Достаточно набрать её по ошибке или перепутать с `verify`, чтобы уронить
  # рабочий узел. Деструктивное действие обязано переспрашивать.
  printf '  Будут ОСТАНОВЛЕНЫ все контейнеры этой ноды:\n'
  printf '    HAProxy, Caddy, Xray и агент метрик — узел перестанет\n'
  printf '    принимать клиентов немедленно.\n'
  printf '  Также снимутся cron-хуки синхронизации сертификатов и сбора\n'
  printf '  состояния контейнеров.\n\n'
  if [[ "${RW_FORCE_ROLLBACK:-}" != '1' ]] && ! confirm_typed 'Подтвердите откат' 'ROLLBACK'; then
    info 'Откат отменён, ничего не тронуто.'
    return 0
  fi

  warn 'Останавливаю только контейнеры, созданные этим установщиком.'
  docker compose -f "${INSTALL_DIR}/docker-compose.node.yml" down 2>/dev/null || true
  docker compose -f "${INSTALL_DIR}/docker-compose.edge.yml" down 2>/dev/null || true
  docker compose -f "${INSTALL_DIR}/monitoring/docker-compose.yml" down 2>/dev/null || true
  rm -f /etc/cron.d/rw-edge-certs /etc/cron.d/rw-docker-textfile
  rm -f /usr/local/bin/rw-docker-textfile.sh
  log 'Контейнеры остановлены, cron-хуки сняты.'
  printf '\n  Намеренно НЕ тронуто: файлы в %s, тома Caddy с сертификатами,\n' "${INSTALL_DIR}"
  printf '  правила UFW и sysctl. Удаляйте вручную, если это действительно нужно:\n'
  printf '    rm -rf %s\n' "${INSTALL_DIR}"
  printf '    rm -f /etc/sysctl.d/99-rw-edge.conf /etc/security/limits.d/99-rw-edge.conf\n'
  printf '    docker volume rm rw-edge_caddy_data rw-edge_caddy_config\n'
}

# ====================================================================== main ==

usage() {
  cat <<EOF
${SELF_CMD} — rw-edge installer ${SCRIPT_VERSION}

  install    полная установка (по умолчанию)
  verify     повторить проверки вживую
  steps      снова показать инструкцию для панели
  rollback   остановить контейнеры установщика

Переменные окружения:
  RW_ENABLE_UFW=1     включить UFW без интерактивного подтверждения
  RW_METRICS_URL=...  адрес remoteWrite; задан — метрики включаются без вопроса
  RW_METRICS_USER=...
  RW_METRICS_PASS=...
  RW_ACME_STAGING=1   ACME staging: недоверенные сертификаты, без лимитов (тесты)
EOF
}

main() {
  local action="${1:-install}"

  case "${action}" in
    install)
      need_cmd ss
      preflight
      install_docker
      ask_panel
      ask_variants
      ask_domains
      verify_dns
      ask_site
      ask_monitoring
      pull_images
      generate_material

      mkdir -p "${INSTALL_DIR}" "${PRIVATE_DIR}"
      chmod 0700 "${PRIVATE_DIR}"
      self_install

      render_site
      render_xray_profile
      render_haproxy
      render_caddyfile
      render_compose
      render_client_template
      render_monitoring
      save_state

      tune_kernel
      setup_firewall
      install_cert_sync
      deploy_edge
      wait_for_certs
      validate_artifacts
      deploy_node
      deploy_monitoring
      verify_runtime
      verify_monitoring

      printf '\n'
      log 'Серверная часть готова.'
      print_instructions
      ;;
    verify)
      load_state || die "Нет состояния в ${STATE_FILE}. Сначала запустите install."
      verify_runtime
      verify_monitoring ;;
    steps)
      load_state || die "Нет состояния в ${STATE_FILE}."
      print_instructions ;;
    rollback)
      do_rollback ;;
    -h|--help|help)
      usage ;;
    *)
      usage; die "Неизвестная команда: ${action}" ;;
  esac
}

main "$@"
