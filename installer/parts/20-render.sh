
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
      hysteria2) : ;;  # UDP only, HAProxy is not involved
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
