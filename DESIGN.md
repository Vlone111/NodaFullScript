# RW Edge Installer — контракт архитектуры

Этот файл описывает, что именно генерирует установщик. Он не документация
«вообще», а контракт: генератор конфигов и валидатор обязаны ему соответствовать.

## Порты

| Порт | Кто слушает | Публичный |
|---|---|---|
| TCP/443 | HAProxy | да |
| UDP/443 | Xray, inbound Hysteria2 | да, только если выбран Hysteria2 |
| TCP/22 | sshd | да, сужается до фактического порта |
| TCP/`NODE_PORT` | RemnaNode API | только с IP панели |
| 127.0.0.1:18443-18449 | Xray backends | нет |
| 127.0.0.1:19443 | Caddy TLS (cover + XHTTP/gRPC origin) | нет |
| 127.0.0.1:19080 | Caddy plain HTTP origin для Hysteria masquerade | нет |
| 127.0.0.1:8404 | HAProxy stats | нет |

UDP/443 может держать только один процесс. Поэтому при выбранном Hysteria2
Caddy **не** объявляет HTTP/3: `protocols h1 h2`. Весь QUIC на 443 обслуживает
Xray, а неаутентифицированный — отдаёт в masquerade на локальный сайт.

## Варианты

`NEED_DOMAIN` — нужен ли собственный домен с A-записью на этот сервер.
`CERT` — нужен ли публичный сертификат Let's Encrypt.

| id | Протокол | Транспорт | Security | Backend | NEED_DOMAIN | CERT | Кто терминирует TLS |
|---|---|---|---|---|---:|---:|---|
| `reality-tcp-steal` | VLESS | raw | REALITY | 18443 | 1 | да | Xray (REALITY), fallback → Caddy |
| `reality-tcp-borrow` | VLESS | raw | REALITY | 18443 | 0 | нет | Xray (REALITY), target — внешний сайт |
| `reality-xhttp-steal` | VLESS | xhttp | REALITY | 18445 | 1 | да | Xray (REALITY), fallback → Caddy |
| `xhttp-tls` | VLESS | xhttp | none | 18444 | 1 | да | Caddy, дальше h2c в Xray |
| `grpc-tls` | VLESS | grpc | none | 18447 | 1 | да | Caddy, дальше h2c в Xray |
| `tcp-tls` | VLESS | raw | tls | 18446 | 1 | да | Xray, сертификат смонтирован |
| `hysteria2` | Hysteria2 | quic | tls | UDP/443 | 1 | да | Xray, сертификат смонтирован |

### Взаимоисключения, которые установщик обязан проверять

1. `reality-tcp-steal` и `reality-tcp-borrow` вместе **запрещены**: оба
   претендуют на один `default_backend` HAProxy и на один RAW-инбаунд.
2. Один домен — один вариант. Исключение: `hysteria2` живёт на UDP и может
   переиспользовать домен любого TCP-варианта. Установщик это предлагает явно.
3. `reality-*-steal` требует, чтобы его домен обслуживался локальным Caddy:
   REALITY `target` указывает на `127.0.0.1:19443`, а не на публичный адрес,
   иначе получается петля HAProxy → Xray → 443 → HAProxy.
4. `reality-tcp-borrow` требует внешний домен-донор, который: отвечает TLS 1.3,
   поддерживает X25519, не принадлежит нам и не находится в РФ.

## Разводка TCP/443

HAProxy работает в `mode tcp`, TLS не терминирует, читает только SNI из
ClientHello.

```text
ClientHello
   │
   ├── ALPN acme-tls/1 ............................ → Caddy 19443  (ACME renewal)
   ├── SNI == домен reality-*-steal ............... → Xray backend этого варианта
   ├── SNI == домен tcp-tls ....................... → Xray 18446
   ├── SNI == домен xhttp-tls | grpc-tls .......... → Caddy 19443 → h2c → Xray
   └── default .................................... → Xray RAW backend, иначе Caddy
```

`default_backend` уходит в RAW-инбаунд, если выбран любой `reality-tcp-*`:
REALITY сам решает, что делать с неаутентифицированным ClientHello. Если
REALITY-варианта нет, default идёт в Caddy, чтобы на любой мусорный SNI
отвечал настоящий сайт, а не обрыв.

## Сертификаты

Единственный ACME-клиент — Caddy, challenge TLS-ALPN-01 через публичный 443,
пробрасывается HAProxy по ALPN. Порт 80 не открывается.

`tcp-tls` и `hysteria2` требуют файлов сертификата внутри контейнера ноды.
Caddy складывает их в свой volume; хук синхронизации копирует в
`/opt/rw-edge/certs/<domain>/{fullchain.pem,privkey.pem}`, а нода монтирует эту
папку read-only. В Xray у таких inbound `oneTimeLoading: false`, поэтому после
обновления сертификата перезапуск не нужен — ядро перечитает файлы само.

## Что установщик не делает

- не трогает Panel: он только печатает точные значения для ручного ввода;
- не открывает Node API шире, чем на IP панели;
- не включает UFW без явного подтверждения и без allow на фактический SSH-порт;
- не запускается повторно вслепую: повторный запуск читает сохранённое
  состояние и предлагает либо доустановить, либо откатиться.
