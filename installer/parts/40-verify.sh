
# ========================================================= client template ====

render_client_template() {
  local out="${PRIVATE_DIR}/xray-json-template.json"
  local n=0 v sel=()

  for v in "${SELECTED[@]}"; do
    # Xray does have a hysteria OUTBOUND (verified on 26.6.27), so this could
    # live in the template — except hysteriaSettings.auth is the per-user
    # password. Hardcoding it here would put every client on one credential and
    # destroy per-user accounting, HWID and revocation. It only belongs in the
    # template if the Panel injects the password itself; see the printed steps.
    [[ "${v}" == 'hysteria2' ]] && continue
    n=$((n + 1))
    sel+=("__HOST_UUID_${n}__")
  done
  (( n > 0 )) || { info 'Клиентский XRAY_JSON не нужен: выбран только Hysteria2.'; return 0; }

  local values
  values="$(printf '%s\n' "${sel[@]}" | jq -R . | jq -s .)"

  jq -n --argjson values "${values}" '{
    remnawave: {
      injectHosts: [{
        selector: {type: "uuids", values: $values},
        selectFrom: "NOT_HIDDEN",
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
    printf '  EXCLUDE FORMATS — трогать только в одном случае:\n'
    printf '    Если вы поднимете виртуальный Host с Xray JSON Template (шаг 5),\n'
    printf '    физические Hosts попадут клиенту дважды: обычной записью и как\n'
    printf '    outbound внутри шаблона. Тогда у физических исключите XRAY_JSON,\n'
    printf '    а у виртуального — всё КРОМЕ XRAY_JSON.\n'
    printf '    Без виртуального Host НИЧЕГО не исключайте: Happ получает именно\n'
    printf '    XRAY_JSON, и с исключением он не увидит ни одного сервера.\n'
    printf '    Проверка после настройки — сколько записей в подписке:\n'
    printf '      curl -s -A "Happ/2.0" "<ссылка>/json" | jq "if type==\\"array\\" then length else 1 end"\n'
    printf '      1 — схема с шаблоном работает; 3+ — дубли, нужно исключение;\n'
    printf '      0 или ошибка — исключено лишнее.\n\n'

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
      printf '    Visible ............ да\n\n'
    done

    if [[ -f "${PRIVATE_DIR}/xray-json-template.json" ]]; then
      printf 'ШАГ 4. XRAY JSON TEMPLATE\n'
      printf '  Subscription -> Templates -> Xray JSON -> создать и вставить:\n'
      printf '    %s\n\n' "${PRIVATE_DIR}/xray-json-template.json"
      printf '  Перед вставкой замените плейсхолдеры на UUID созданных Hosts:\n'
      local n=0
      for v in "${SELECTED[@]}"; do
        [[ "${v}" == 'hysteria2' ]] && continue
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
      printf '    Exclude formats .... всё, КРОМЕ XRAY_JSON\n'
      printf '    Visible ............ да\n\n'
      printf '  Физические Hosts исключены из XRAY_JSON намеренно: иначе клиент\n'
      printf '  увидит их и отдельными записями, и внутри шаблона.\n\n'
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
      printf '  Умеет ли ваша Panel инжектить hysteria — проверяется так:\n'
      printf '    1. У Hysteria2-хоста убрать XRAY_JSON из Exclude formats.\n'
      printf '    2. Добавить его UUID в remnawave.injectHosts шаблона.\n'
      printf '    3. curl -s -A "Happ/2.0" "<ссылка>/json" \\\n'
      printf '         | jq %s.outbounds[] | select(.protocol==\"hysteria\")%s\n\n' "'" "'"
      printf '  Появился блок с непустым auth — работает, оставляйте так.\n'
      printf '  Пусто или auth пустой — Panel не умеет: верните исключение и НЕ\n'
      printf '  хардкодьте пароль. Тогда Hysteria2 остаётся отдельной записью, а\n'
      printf '  клиентам, читающим только XRAY_JSON, она видна не будет.\n\n'
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
      printf '  не появится. В scrape-конфиг сервера мониторинга добавьте:\n\n'
      printf '    - job_name: blackbox-tcp\n'
      printf '      metrics_path: /probe\n'
      printf '      params: {module: [tcp_connect]}\n'
      printf '      static_configs:\n'
      printf "        - targets: ['%s:443']\n" "${EDGE_IPV4}"
      printf '          labels: {vantage: billing, target: %s}\n' "${NODE_CODE}"
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
