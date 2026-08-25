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

# убийство прошлых экземпляров без pgrep (его нет в контейнере ноды)
KILLER='for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  if tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -q xhttp-client.json; then
    kill "${p#/proc/}" 2>/dev/null
  fi
done'

hdr "2. Запускаю тестовый клиент Xray"
docker exec "$CT" sh -c "$KILLER" 2>/dev/null || true
sleep 1

# ВАЖНО: xray запускается через exec на переднем плане внутри docker exec -d.
# Если увести его в фон через '&', шелл завершится и Docker убьёт процесс.
docker exec -d "$CT" sh -c 'exec xray run -c /tmp/xhttp-client.json > /tmp/xhttp-client.log 2>&1'

# ждём появления слушающего сокета (до 15 сек)
UP=0
for i in $(seq 1 15); do
  if ss -tlnH "sport = :${SOCKS}" 2>/dev/null | grep -q .; then UP=1; break; fi
  sleep 1
done

if [[ $UP -eq 1 ]]; then
  ok "клиент запущен, socks5 слушает 127.0.0.1:${SOCKS}"
else
  bad "порт ${SOCKS} не слушается. Лог клиента:"
  docker exec "$CT" sh -c 'tail -25 /tmp/xhttp-client.log' 2>/dev/null | sed 's/^/       /'
  docker exec "$CT" sh -c "$KILLER" 2>/dev/null || true
  exit 1
fi

hdr "3. Пробую выйти в интернет через сервер"
echo "  запрос: curl --socks5-hostname 127.0.0.1:${SOCKS} https://api.ipify.org"
CURLERR=$(mktemp)
RESULT=$(curl -sS --max-time 25 --socks5-hostname "127.0.0.1:${SOCKS}" https://api.ipify.org 2>"$CURLERR")
CRC=$?
[[ -s "$CURLERR" ]] && echo -e "  ${Y}curl:${N} $(tr -d '\n' < "$CURLERR")"
[[ $CRC -ne 0 ]] && echo -e "  ${Y}код возврата curl:${N} ${CRC}"
rm -f "$CURLERR"

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
  echo -e "${Y}  Лог клиента (последние 40 строк):${N}"
  docker exec "$CT" sh -c 'tail -40 /tmp/xhttp-client.log' 2>/dev/null | sed 's/^/    /'
  echo
  echo -e "${Y}  Как читать лог:${N}"
  echo -e "    · есть строки про ${B}dial${N}/${B}connection${N}, но потом ошибка → клиент дошёл до сервера,"
  echo -e "      причина в UUID (юзер не в этом инбаунде) или в path/host"
  echo -e "    · ${B}нет ни одной строки${N} после \"started\" → запрос вообще не дошёл до outbound"
  echo -e "    · ${B}context deadline exceeded${N} → сервер не отвечает на XHTTP по этому пути"
  echo
  echo -e "${Y}  Что проверить:${N}"
  echo -e "    · UUID ${UUID:0:8}… действительно привязан к инбаунду VLESS_XHTTP_MEDIA"
  echo -e "    · path инбаунда на ноде = ${XPATH}"
  echo -e "    · host инбаунда на ноде = ${DOMAIN}"
fi

hdr "4. Убираю за собой"
docker exec "$CT" sh -c "$KILLER" 2>/dev/null || true
docker exec "$CT" sh -c 'rm -f /tmp/xhttp-client.json /tmp/xhttp-client.log' 2>/dev/null || true
rm -f /tmp/xhttp-client.json
ok "тестовый клиент остановлен, временные файлы удалены"
echo
