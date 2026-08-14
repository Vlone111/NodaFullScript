
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
# 32 MB rather than 16: the bandwidth-delay product on a Russia-to-Europe path
# at 100 ms exceeds what 16 MB can keep in flight, and the window stops growing
# right where the link would have gone faster.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# core.*mem_max only raises the ceiling a socket may ask for. TCP has its own
# autotuning triple, and without raising it the ceiling above is never reached.
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432

# UDP has no autotuning at all — these are floors, and the defaults are what
# makes Hysteria2 drop packets under load on an otherwise idle link.
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

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
