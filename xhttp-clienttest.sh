#!/usr/bin/env bash
#
#  XHTTP client test — проверка связки настоящим клиентом Xray
#  bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/xhttp/main/xhttp-clienttest.sh)
#
#  Поднимает локальный Xray-клиент с заведомо правильными параметрами
#  и пробует выйти в интернет через ваш же сервер.
#
set -uo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'; N='\033[0m'
ok(){ echo -e "  ${G}[OK]${N}   $*"; }
bad(){ echo -e "  ${R}[FAIL]${N} $*"; }
warn(){ echo -e "  ${Y}[??]${N}   $*"; }
hdr(){ echo -e "\n${B}── $* ─────────────────────────${N}"; }

[[ $EUID -eq 0 ]] || { echo "Запустите от root"; exit 1; }

CT="${CT:-remnanode}"
SOCKS=10809

docker ps --format '{{.Names}}' | grep -qx "$CT" || { bad "контейнер ${CT} не найден"; exit 1; }

# ── параметры ──
DOMAIN="${DOMAIN:-}"
[[ -z "$DOMAIN" ]] && read -rp "Домен: " DOMAIN < /dev/tty

XPATH="${XPATH:-}"
if [[ -z "$XPATH" ]]; then
  XPATH=$(grep -oP 'path /v1/stream/[A-Za-z0-9_-]+' /etc/caddy/Caddyfile 2>/dev/null | head -1 | awk '{print $2}')
  [[ -z "$XPATH" ]] && XPATH=$(grep -oP '(?<=handle )/v1/stream/[A-Za-z0-9_-]+' /etc/caddy/Caddyfile 2>/dev/null | head -1)
fi
[[ -z "$XPATH" ]] && read -rp "Path (/v1/stream/...): " XPATH < /dev/tty

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

UUID="${UUID:-}"
if [[ -z "$UUID" ]]; then
  echo -e "\n${Y}Нужен VLESS-UUID пользователя (НЕ короткий ID подписки).${N}"
  echo -e "${Y}Где взять: панель → любой юзер → ссылка подключения${N}"
  echo -e "${Y}  vless://${G}6604f701-f025-4daf-a74e-f21a87670ea4${Y}@домен:443?...${N}"
  echo -e "${Y}            ^^^^^^^^^ вот это, между vless:// и @${N}\n"
  read -rp "UUID пользователя: " UUID < /dev/tty
fi

# можно вставить всю ссылку целиком — вытащим UUID сами
if [[ "$UUID" == vless://* ]]; then
  UUID=$(echo "$UUID" | sed -E 's|^vless://([^@]+)@.*|\1|')
  ok "UUID извлечён из ссылки"
fi

if ! [[ "$UUID" =~ $UUID_RE ]]; then
  bad "Это не похоже на VLESS-UUID: ${UUID}"
  echo -e "  ${Y}Ожидается формат 8-4-4-4-12, например:${N}"
  echo -e "  ${Y}  6604f701-f025-4daf-a74e-f21a87670ea4${N}"
  echo -e "  ${Y}Короткий ID подписки (вида -spDDGysn782uTuA) НЕ подойдёт —${N}"
  echo -e "  ${Y}сервер такого пользователя не опознает.${N}\n"
  read -rp "Всё равно продолжить? [y/N]: " GO < /dev/tty
  [[ "${GO,,}" == y* ]] || exit 1
fi

echo -e "\n  Домен : ${DOMAIN}\n  Path  : ${XPATH}\n  UUID  : ${UUID:0:8}…\n"

# ── конфиг клиента ──
cat > /tmp/xhttp-client.json <<EOF
{
  "log": { "loglevel": "debug" },
  "inbounds": [
    {
      "tag": "socks-test",
      "listen": "127.0.0.1",
      "port": ${SOCKS},
      "protocol": "socks",
      "settings": { "udp": false, "auth": "noauth" }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${DOMAIN}",
            "port": 443,
            "users": [ { "id": "${UUID}", "encryption": "none" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "alpn": ["h2"],
          "fingerprint": "chrome"
        },
        "xhttpSettings": {
          "host": "${DOMAIN}",
          "path": "${XPATH}",
          "mode": "auto"
        }
      }
    }
  ]
}
EOF

hdr "1. Заливаю конфиг клиента в контейнер"
docker exec -i "$CT" sh -c 'cat > /tmp/xhttp-client.json' < /tmp/xhttp-client.json \
  && ok "конфиг записан" || { bad "не удалось записать конфиг"; exit 1; }

hdr "2. Запускаю тестовый клиент Xray"
docker exec "$CT" sh -c 'kill $(cat /tmp/xhttp-client.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/xhttp-client.pid' 2>/dev/null || true
sleep 1
docker exec -d "$CT" sh -c 'xray run -c /tmp/xhttp-client.json > /tmp/xhttp-client.log 2>&1 & echo $! > /tmp/xhttp-client.pid'
sleep 4

# Надёжная проверка: ищем в логе факт запуска (pgrep в контейнере может отсутствовать)
if docker exec "$CT" sh -c 'grep -qE "core: Xray .* started" /tmp/xhttp-client.log' 2>/dev/null; then
  ok "клиент запущен (socks5 на 127.0.0.1:${SOCKS})"
elif docker exec "$CT" sh -c 'grep -qi "listening TCP on 127.0.0.1:'"${SOCKS}"'" /tmp/xhttp-client.log' 2>/dev/null; then
  ok "клиент слушает socks5 на 127.0.0.1:${SOCKS}"
else
  bad "клиент не стартовал. Лог:"
  docker exec "$CT" sh -c 'tail -25 /tmp/xhttp-client.log' 2>/dev/null | sed 's/^/       /'
  exit 1
fi

hdr "3. Пробую выйти в интернет через сервер"
RESULT=$(curl -sS --max-time 25 --socks5-hostname "127.0.0.1:${SOCKS}" https://api.ipify.org 2>&1 || echo "")

if [[ "$RESULT" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo
  ok "ТУННЕЛЬ РАБОТАЕТ. Внешний IP через прокси: ${RESULT}"
  echo
  echo -e "${G}  ═══════════════════════════════════════════════════${N}"
  echo -e "${G}  Сервер полностью исправен.${N}"
  echo -e "${G}  Проблема — в настройках ХОСТА в панели Remnawave.${N}"
  echo -e "${G}  ═══════════════════════════════════════════════════${N}"
  echo
  echo -e "  Выставьте в хосте ровно эти значения:"
  echo -e "    Address     : ${DOMAIN}"
  echo -e "    Port        : ${B}443${N}   ${Y}(НЕ 8001!)${N}"
  echo -e "    Security    : ${B}TLS${N}   ${Y}(принудительно, инбаунд отдаёт none)${N}"
  echo -e "    SNI / Host  : ${DOMAIN}"
  echo -e "    Path        : ${XPATH}"
  echo -e "    ALPN        : h2"
  echo -e "    Fingerprint : chrome"
else
  bad "туннель не поднялся"
  echo
  echo -e "${Y}  Лог клиента (последние 30 строк):${N}"
  docker exec "$CT" sh -c 'tail -30 /tmp/xhttp-client.log' 2>/dev/null | sed 's/^/    /'
  echo
  echo -e "${Y}  Частые причины:${N}"
  echo -e "    · UUID не принадлежит этому инбаунду / юзер отключён"
  echo -e "    · path в клиенте не совпадает с path инбаунда"
  echo -e "    · host в инбаунде Xray не равен ${DOMAIN}"
fi

hdr "4. Убираю за собой"
docker exec "$CT" sh -c 'kill $(cat /tmp/xhttp-client.pid 2>/dev/null) 2>/dev/null; rm -f /tmp/xhttp-client.json /tmp/xhttp-client.pid /tmp/xhttp-client.log' 2>/dev/null || true
rm -f /tmp/xhttp-client.json
ok "тестовый клиент остановлен, временные файлы удалены"
echo
