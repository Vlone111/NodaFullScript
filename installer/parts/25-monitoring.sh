
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
