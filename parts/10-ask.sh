
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

  ACME_EMAIL="$(ask 'E-mail для Let'\''s Encrypt (уведомления об истечении)' "admin@${PANEL_IPV4}.nip.io")"
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

verify_one_domain() {
  local domain="$1" resolver answer ok=0
  for resolver in 9.9.9.9 77.88.8.8; do
    answer="$(dig +short +time=4 +tries=2 "@${resolver}" "${domain}" A 2>/dev/null | tail -1)"
    if [[ "${answer}" == "${EDGE_IPV4}" ]]; then
      ok=$((ok + 1))
    else
      warn "${domain} через ${resolver} → '${answer:-нет ответа}', ожидался ${EDGE_IPV4}."
    fi
  done

  local aaaa
  aaaa="$(dig +short +time=4 "@9.9.9.9" "${domain}" AAAA 2>/dev/null | tail -1)"
  [[ -n "${aaaa}" ]] && warn "У ${domain} есть AAAA (${aaaa}). Клиенты пойдут по IPv6, которого на узле нет. Удалите запись."

  if (( ok < 2 )); then
    if ! confirm "DNS для ${domain} ещё не сошёлся. Продолжить всё равно"; then
      die 'Дождитесь распространения DNS и запустите снова.'
    fi
  else
    log "${domain} → ${EDGE_IPV4}"
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

  local keys
  keys="$(docker run --rm --pull never --network none --cap-drop ALL --read-only \
    --entrypoint /usr/local/bin/xray "${NODE_IMAGE}" x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "${keys}" | sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' | head -n1)"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "${keys}" | sed -nE 's/^(Password \(PublicKey\)|Password|PublicKey|Public key):[[:space:]]*//p' | head -n1)"
  [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] || die 'Xray не выдал пару ключей REALITY.'

  REALITY_SHORT_ID="$(rand_hex 8)"
  XHTTP_PATH="/api/v1/$(rand_hex 24)/"
  GRPC_SERVICE="api.v1.$(rand_hex 6)"

  log 'REALITY-пара, short ID, XHTTP-путь и gRPC-сервис сгенерированы.'
}
