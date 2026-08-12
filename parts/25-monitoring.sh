
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

  printf '  Нода может отправлять свои метрики на ваш сервер мониторинга:\n'
  printf '  загрузку CPU и памяти, диск, трафик по интерфейсам, состояния TCP.\n'
  printf '  Панель для этого не нужна, входящих портов не открывается —\n'
  printf '  соединение всегда исходящее.\n\n'

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

monitoring_enabled() { [[ -n "${METRICS_URL:-}" ]]; }

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
EOF
  chmod 0644 "${dir}/scrape.yml"

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
      - '--no-collector.wifi'
      - '--no-collector.hwmon'
      - '--no-collector.thermal_zone'
    volumes:
      - /:/host:ro,rslave
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
    depends_on: [node-exporter]
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
  docker pull --quiet "${VMAGENT_IMAGE}" >/dev/null
  docker compose -f "${INSTALL_DIR}/monitoring/docker-compose.yml" up -d --remove-orphans
  sleep 5
  docker ps --filter name=rw-node-exporter --filter name=rw-vmagent \
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
  scraped="$(curl -fsS --max-time 5 http://127.0.0.1:8429/metrics 2>/dev/null \
    | awk '/^vm_promscrape_scrapes_total/ {s+=$2} END {printf "%d", s+0}')"
  sent="$(curl -fsS --max-time 5 http://127.0.0.1:8429/metrics 2>/dev/null \
    | awk '/^vmagent_remotewrite_requests_total.*status_code="2/ {s+=$2} END {printf "%d", s+0}')"

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
