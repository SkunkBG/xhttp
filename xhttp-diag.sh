#!/usr/bin/env bash
#
#  XHTTP Media Stub — диагностика
#  bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/xhttp/main/xhttp-diag.sh)
#
set -uo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'; N='\033[0m'
ok(){   echo -e "  ${G}[OK]${N}   $*"; }
bad(){  echo -e "  ${R}[FAIL]${N} $*"; }
warn(){ echo -e "  ${Y}[??]${N}   $*"; }
hdr(){  echo -e "\n${B}── $* ─────────────────────────────${N}"; }
# curl сам печатает 000 при сбое соединения — дописывать код через `|| echo` нельзя
http_code() {
  local c
  c=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "${2:-8}" "$1" 2>/dev/null) || true
  echo "${c:-000}"
}
# ответ пришёл от API-заглушки Caddy, а не от Xray
is_stub() {
  local b
  b=$(curl -sS --max-time "${2:-6}" "$1" 2>/dev/null | tr -d '\0' | head -c 2000) || true
  [[ "$b" == *resource_not_found* ]]
}

[[ $EUID -eq 0 ]] || { echo "Запустите от root"; exit 1; }

DOMAIN="${DOMAIN:-}"
[[ -z "$DOMAIN" ]] && read -rp "Домен: " DOMAIN < /dev/tty

# путь вытаскиваем из Caddyfile
XPATH=$(grep -oP '(?<=handle )/v1/stream/[A-Za-z0-9_-]+' /etc/caddy/Caddyfile 2>/dev/null | head -n1)
[[ -z "$XPATH" ]] && XPATH=$(grep -oP 'path /v1/stream/[A-Za-z0-9_-]+' /etc/caddy/Caddyfile 2>/dev/null | head -n1 | awk '{print $2}')
XPORT=$(grep -oP '(?<=reverse_proxy 127\.0\.0\.1:)\d+' /etc/caddy/Caddyfile 2>/dev/null | head -n1)
XPORT="${XPORT:-8001}"

echo -e "\n  Домен : ${DOMAIN}\n  Path  : ${XPATH:-<не найден>}\n  Порт  : ${XPORT}"

# ─────────────────────────────────────────
hdr "1. Caddy"
if systemctl is-active --quiet caddy; then ok "служба активна"; else bad "служба не запущена"; fi
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  ok "Caddyfile валиден"
else
  bad "Caddyfile невалиден:"; caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 | tail -5 | sed 's/^/       /'
fi

# ─────────────────────────────────────────
hdr "2. Порты"
ss -tlnpH 2>/dev/null | grep -E ':(80|443)\s' | sed 's/^/  /' | head -4
if ss -tlnH "sport = :${XPORT}" 2>/dev/null | grep -q .; then
  OWN=$(ss -tlnpH "sport = :${XPORT}" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -n1)
  ok "порт ${XPORT} слушается процессом: ${OWN:-?}"
  LADDR=$(ss -tlnH "sport = :${XPORT}" 2>/dev/null | awk '{print $4}' | head -n1)
  case "$LADDR" in
    127.0.0.1:*|"[::1]":*) ok "слушает только localhost (${LADDR})" ;;
    *) bad "слушает на ${LADDR} — инбаунд без TLS доступен снаружи, нужен listen 127.0.0.1" ;;
  esac
else
  bad "НИКТО не слушает 127.0.0.1:${XPORT} — Xray-инбаунд XHTTP не поднят!"
  echo -e "       ${Y}Это и есть причина. Конфиг Xray не применён на ноде.${N}"
fi

# ─────────────────────────────────────────
hdr "3. Docker (сетевой режим ноды)"
if command -v docker >/dev/null 2>&1; then
  CID=$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | grep -iE 'remnanode|remnawave|xray' | awk '{print $1}' | head -n1)
  if [[ -n "$CID" ]]; then
    NAME=$(docker inspect -f '{{.Name}}' "$CID" 2>/dev/null | tr -d /)
    MODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CID" 2>/dev/null)
    if [[ "$MODE" == "host" ]]; then
      ok "контейнер ${NAME}: network_mode=host (правильно)"
    else
      bad "контейнер ${NAME}: network_mode=${MODE}"
      echo -e "       ${Y}Caddy не достучится до 127.0.0.1:${XPORT} внутри контейнера.${N}"
      echo -e "       ${Y}Нужен network_mode: host в docker-compose ноды.${N}"
    fi
  else
    warn "контейнер ноды не найден (возможно, Xray стоит системно)"
  fi
else
  warn "docker не установлен — вероятно Xray системный"
fi

# ─────────────────────────────────────────
hdr "4. HTTPS и заглушка"
for p in "/v1/health" "/v1/catalog" "/"; do
  C=$(http_code "https://${DOMAIN}${p}")
  if [[ "$C" == "200" ]]; then ok "${p} → ${C}"; else bad "${p} → ${C}"; fi
done
PROTO=$(curl -sS -o /dev/null -w '%{http_version}' --max-time 8 "https://${DOMAIN}/" 2>/dev/null || echo "?")
[[ "$PROTO" == "2" ]] && ok "HTTP/2 работает" || warn "HTTP-версия: ${PROTO}"

# ─────────────────────────────────────────
hdr "5. Проксирование XHTTP-пути (ключевой тест)"
if [[ -z "$XPATH" ]]; then
  bad "путь не найден в Caddyfile — проверьте конфиг"
else
  for u in "${XPATH}" "${XPATH}/" "${XPATH}/test123"; do
    if is_stub "https://${DOMAIN}${u}"; then
      bad "${u} → ответ API-заглушки (ушло НЕ в Xray)"
      continue
    fi
    C=$(http_code "https://${DOMAIN}${u}" 6)
    case "$C" in
      502|000) warn "${u} → ${C}  (Caddy проксирует, но Xray не отвечает)" ;;
      *)       ok   "${u} → ${C}  (ответил Xray)" ;;
    esac
  done
  echo -e "\n  ${B}Как читать:${N} заглушку узнаём по телу ответа, а не по коду —"
  echo -e "  404 умеет отдавать и сам Xray (например, на путь без завершающего слэша)."
  echo -e "  502/000 = Caddy проксирует, но инбаунд не поднят."
fi

# ─────────────────────────────────────────
hdr "6. Прямой стук в Xray, минуя Caddy"
C=$(http_code "http://127.0.0.1:${XPORT}${XPATH:-}/" 5)
if [[ "$C" == "000" ]]; then
  bad "127.0.0.1:${XPORT} не отвечает — Xray-инбаунд не работает"
else
  ok "Xray отвечает на 127.0.0.1:${XPORT} (код ${C})"
fi

# ─────────────────────────────────────────
hdr "7. Логи Caddy (последние ошибки)"
journalctl -u caddy --no-pager -n 200 2>/dev/null | grep -iE 'error|refused|dial|upstream' | tail -8 | sed 's/^/  /' \
  || echo "  (ошибок не найдено)"

echo -e "\n${B}────────────────────────────────────────────${N}"
echo -e "Пришлите вывод целиком — по нему видно причину.\n"
