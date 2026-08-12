#!/usr/bin/env bash
# Render every supported combination and validate each artifact with the real
# pinned Xray, HAProxy and Caddy. No system state is touched.
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

# Source the generators without running main().
sed '/^main "\$@"$/d' "${here}/rw-edge-install.sh" >"${work}/lib.sh"
# Redirect the installer's paths into the sandbox.
sed -i \
  -e "s#^readonly INSTALL_DIR=.*#readonly INSTALL_DIR='${work}/opt'#" \
  -e "s#^readonly PRIVATE_DIR=.*#readonly PRIVATE_DIR='${work}/opt/private'#" \
  -e "s#^readonly SITE_DIR=.*#readonly SITE_DIR='${work}/site'#" \
  -e "s#^readonly CERT_DIR=.*#readonly CERT_DIR='${work}/certs'#" \
  -e "s#^readonly STATE_FILE=.*#readonly STATE_FILE='${work}/opt/private/state.env'#" \
  "${work}/lib.sh"

set +e
# shellcheck disable=SC1090
source "${work}/lib.sh" >/dev/null 2>&1
set -e
trap - ERR

mkdir -p "${work}/opt/private" "${work}/site" "${work}/certs"
# Заглушка вместо настоящего сайта: матрица проверяет конфиги, а не вёрстку.
# Копии сайта в этом репозитории намеренно нет — он отдаётся публично на каждой
# ноде, и соседство с исходниками установщика выдавало бы прикрытие.
# Caddyfile ссылается ровно на эти четыре файла.
printf '<!doctype html><title>stub</title>\n' >"${work}/site/index.html"
printf '<!doctype html><title>404</title>\n'  >"${work}/site/404.html"
printf 'User-agent: *\nAllow: /\n'           >"${work}/site/robots.txt"
printf '<?xml version="1.0"?><urlset/>\n'     >"${work}/site/sitemap.xml"

NODE_IMAGE_T='remnawave/node:2.8.0'
CADDY_IMAGE_T='caddy@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648'
HAPROXY_IMAGE_T='haproxy@sha256:79799e8b2977e60802774fa53d29e6b54e045402cdd8a8b9fe43923e7095a047'

# Fixed material so runs are reproducible.
EDGE_IPV4='203.0.113.10'
NODE_CODE='TEST'
ACME_EMAIL='ops@example.net'
REALITY_SHORT_ID='da907f51ee5027f8'
XHTTP_PATH='/api/v1/0123456789abcdef0123456789abcdef0123456789abcdef/'
GRPC_SERVICE='api.v1.abcdef'
BORROW_SNI='www.samsung.com'
keys="$(docker run --rm --network none --entrypoint /usr/local/bin/xray "${NODE_IMAGE_T}" x25519)"
REALITY_PRIVATE_KEY="$(printf '%s\n' "${keys}" | sed -nE 's/^(PrivateKey|Private key):[[:space:]]*//p' | head -n1)"
REALITY_PUBLIC_KEY="$(printf '%s\n' "${keys}" | sed -nE 's/^(Password \(PublicKey\)|Password|PublicKey|Public key):[[:space:]]*//p' | head -n1)"

# Certificates for the variants whose Xray inbound reads files from disk.
mk_cert() {
  local d="$1"
  mkdir -p "${work}/certs/${d}"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${work}/certs/${d}/privkey.pem" \
    -out "${work}/certs/${d}/fullchain.pem" \
    -days 2 -subj "/CN=${d}" >/dev/null 2>&1
}

pass=0; fail=0; failed_cases=()

run_case() {
  local name="$1"; shift
  SELECTED=("$@")
  declare -gA DOMAINS=()

  local v i=1 d
  for v in "${SELECTED[@]}"; do
    if [[ "$(variant_needs_dom "${v}")" == '1' ]]; then
      d="d${i}.example.net"; i=$((i + 1))
      DOMAINS[$v]="${d}"
      [[ "${v}" == 'tcp-tls' || "${v}" == 'hysteria2' ]] && mk_cert "${d}"
    fi
  done

  SITE_DOMAIN=''
  for v in "${SELECTED[@]}"; do
    if [[ "$(variant_needs_crt "${v}")" == '1' && -n "${DOMAINS[$v]:-}" ]]; then
      SITE_DOMAIN="${DOMAINS[$v]}"; break
    fi
  done

  local err=''
  render_xray_profile    >/dev/null 2>&1 || err='render_xray_profile'
  render_haproxy         >/dev/null 2>&1 || err="${err:-render_haproxy}"
  render_caddyfile       >/dev/null 2>&1 || err="${err:-render_caddyfile}"
  render_client_template >/dev/null 2>&1 || err="${err:-render_client_template}"

  if [[ -z "${err}" ]]; then
    docker run --rm --pull never --network none --cap-drop ALL --read-only \
      -v "${work}/certs:/etc/rw-certs:ro" \
      -v "${work}/opt/private/config-profile.json:/etc/xray/config.json:ro" \
      --entrypoint /usr/local/bin/xray "${NODE_IMAGE_T}" \
      run -test -config /etc/xray/config.json >/dev/null 2>&1 || err='xray:server'
  fi

  if [[ -z "${err}" ]]; then
    docker run --rm --pull never --network none --cap-drop ALL --read-only \
      -v "${work}/opt/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
      "${HAPROXY_IMAGE_T}" haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null 2>&1 \
      || err='haproxy'
  fi

  # Валидность конфига ещё не значит, что маршруты осмысленны: отсутствующий
  # ACL — совершенно законный HAProxy. Именно так пролезал баг, при котором
  # домен Hysteria2 не имел правила по SNI, проваливался в default_backend и
  # при borrow-варианте предъявлял сертификат чужого донора.
  # Правило: у каждого домена либо есть свой ACL, либо он принадлежит тому
  # варианту, который владеет default_backend.
  if [[ -z "${err}" ]]; then
    local d v_owner=''
    for v in "${SELECTED[@]}"; do
      [[ "${v}" == 'reality-tcp-steal' || "${v}" == 'reality-tcp-borrow' ]] && v_owner="${v}"
    done
    for v in "${SELECTED[@]}"; do
      d="${DOMAINS[$v]:-}"
      [[ -n "${d}" ]] || continue
      [[ "${v}" == "${v_owner}" ]] && continue
      grep -q "req.ssl_sni -i ${d}\b" "${work}/opt/haproxy.cfg" \
        || { err="sni:${d} без правила"; break; }
    done
  fi

  if [[ -z "${err}" ]]; then
    if ! docker run --rm --pull never --network none \
        --cap-drop ALL --cap-add NET_BIND_SERVICE --read-only \
        --tmpfs /data:rw,size=8m --tmpfs /config:rw,size=2m --tmpfs /run:rw,size=1m \
        -v "${work}/opt/Caddyfile:/etc/caddy/Caddyfile:ro" \
        -v "${work}/site:/srv:ro" \
        "${CADDY_IMAGE_T}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
        >"${work}/caddy.log" 2>&1; then
      err='caddy'
      cp "${work}/opt/Caddyfile" "${work}/failed-Caddyfile.txt"
    fi
  fi

  if [[ -z "${err}" && -f "${work}/opt/private/xray-json-template.json" ]]; then
    local tmp="${work}/client.json"
    jq 'del(.remnawave) | .outbounds = [{
          tag: "proxy", protocol: "vless",
          settings: {vnext: [{address: "127.0.0.1", port: 443, users: [{id: "00000000-0000-0000-0000-000000000000", encryption: "none"}]}]},
          streamSettings: {network: "raw", security: "none"}
        }] + .outbounds' "${work}/opt/private/xray-json-template.json" >"${tmp}" 2>/dev/null
    docker run --rm --pull never --network none --cap-drop ALL --read-only \
      -v "${tmp}:/etc/xray/config.json:ro" \
      --entrypoint /usr/local/bin/xray "${NODE_IMAGE_T}" \
      run -test -config /etc/xray/config.json >/dev/null 2>&1 || err='xray:client'
  fi

  rm -f "${work}/opt/private/xray-json-template.json"

  if [[ -z "${err}" ]]; then
    printf '  \033[32mPASS\033[0m  %s\n' "${name}"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s (%s)\n' "${name}" "${err}"
    fail=$((fail + 1)); failed_cases+=("${name}:${err}")
  fi
}

printf '\nОдиночные варианты\n'
run_case 'reality-tcp-steal'       reality-tcp-steal
run_case 'reality-tcp-borrow'      reality-tcp-borrow
run_case 'reality-xhttp-steal'     reality-xhttp-steal
run_case 'xhttp-tls'               xhttp-tls
run_case 'grpc-tls'                grpc-tls
run_case 'tcp-tls'                 tcp-tls
run_case 'hysteria2'               hysteria2

printf '\nКомбинации\n'
run_case 'steal + xhttp-tls'                   reality-tcp-steal xhttp-tls
run_case 'steal + xhttp-tls + hysteria2'       reality-tcp-steal xhttp-tls hysteria2
run_case 'borrow + grpc-tls'                   reality-tcp-borrow grpc-tls
run_case 'reality-xhttp + tcp-tls'             reality-xhttp-steal tcp-tls
run_case 'steal + xhttp + grpc + tcp-tls'      reality-tcp-steal xhttp-tls grpc-tls tcp-tls
run_case 'всё кроме borrow'                    reality-tcp-steal reality-xhttp-steal xhttp-tls grpc-tls tcp-tls hysteria2
run_case 'borrow + всё TLS + hysteria2'        reality-tcp-borrow xhttp-tls grpc-tls tcp-tls hysteria2

printf '\nACME staging (Caddyfile должен остаться валидным)\n'
SELECTED=(tcp-tls); declare -gA DOMAINS=([tcp-tls]=d1.example.net); SITE_DOMAIN=d1.example.net
mk_cert d1.example.net
RW_ACME_STAGING=1 render_caddyfile >/dev/null 2>&1
if docker run --rm --pull never --network none --cap-drop ALL --cap-add NET_BIND_SERVICE --read-only \
     --tmpfs /data:rw,size=8m --tmpfs /config:rw,size=2m --tmpfs /run:rw,size=1m \
     -v "${work}/opt/Caddyfile:/etc/caddy/Caddyfile:ro" -v "${work}/site:/srv:ro" \
     "${CADDY_IMAGE_T}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  printf '  \033[32mPASS\033[0m  staging Caddyfile валиден\n'; pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  staging Caddyfile отвергнут\n'; fail=$((fail + 1)); failed_cases+=('staging:caddy')
fi

printf '\nОтрицательный тест (должен быть отклонён)\n'
SELECTED=(reality-tcp-steal reality-tcp-borrow)
if validate_selection >/dev/null 2>&1; then
  printf '  \033[31mFAIL\033[0m  steal+borrow пропущены, а должны быть отклонены\n'
  fail=$((fail + 1)); failed_cases+=('steal+borrow:not-rejected')
else
  printf '  \033[32mPASS\033[0m  steal+borrow корректно отклонены\n'
  pass=$((pass + 1))
fi

printf '\n------------------------------------------------------------\n'
printf 'PASS: %d   FAIL: %d\n' "${pass}" "${fail}"
if (( fail > 0 )); then
  printf 'Провалились:\n'
  printf '  %s\n' "${failed_cases[@]}"
  exit 1
fi
printf 'Все комбинации валидны на реальных Xray, HAProxy и Caddy.\n'
