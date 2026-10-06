#!/usr/bin/env bash
#
#  XHTTP Doctor — полная проверка одной командой
#  bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/xhttp/main/xhttp-doctor.sh)
#
#  Проверяет всю цепочку и, главное, разбирает РЕАЛЬНУЮ ссылку из подписки —
#  показывает, что именно получают клиенты.
#
set -uo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'; N='\033[0m'
ok(){ echo -e "  ${G}[OK]${N}   $*"; }
bad(){ echo -e "  ${R}[FAIL]${N} $*"; }
warn(){ echo -e "  ${Y}[??]${N}   $*"; }
hdr(){ echo -e "\n${B}══ $* ═══════════════════════════${N}"; }
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
CT="${CT:-remnanode}"; SOCKS=10809
PROBLEMS=()

# остановка тестового клиента; собственный шелл пропускаем: его cmdline тоже содержит имя конфига
KILLER='for p in /proc/[0-9]*; do [ "${p#/proc/}" = "$$" ] && continue; [ -r "$p/cmdline" ] || continue; if tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -q xd.json; then kill "${p#/proc/}" 2>/dev/null; fi; done'
SUBTMP=""; CLIENT_STARTED=0
# уборка срабатывает и при Ctrl-C
cleanup() {
  [[ -n "$SUBTMP" ]] && rm -f "$SUBTMP"
  if [[ $CLIENT_STARTED -eq 1 ]]; then
    docker exec "$CT" sh -c "$KILLER; rm -f /tmp/xd.json /tmp/xd.log" 2>/dev/null || true
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo -e "\n${B}╔════════════════════════════════════════╗"
echo -e "║   XHTTP Doctor — полная диагностика    ║"
echo -e "╚════════════════════════════════════════╝${N}"

# ── исходные данные ──
DOMAIN="${DOMAIN:-}"
[[ -z "$DOMAIN" ]] && read -rp $'\nДомен ноды: ' DOMAIN < /dev/tty

XPATH=$(grep -oP 'path /v1/stream/[A-Za-z0-9_-]+' /etc/caddy/Caddyfile 2>/dev/null | head -1 | awk '{print $2}')
[[ -z "$XPATH" ]] && XPATH=$(grep -oP '(?<=handle )/v1/stream/[A-Za-z0-9_-]+' /etc/caddy/Caddyfile 2>/dev/null | head -1)
XPORT=$(grep -oP '(?<=reverse_proxy 127\.0\.0\.1:)\d+' /etc/caddy/Caddyfile 2>/dev/null | head -n1)
XPORT="${XPORT:-8001}"

echo -e "\n${Y}Ссылка на подписку любого юзера (панель → юзер → кнопка копирования${N}"
echo -e "${Y}подписки). Это ГЛАВНОЕ — покажет, что реально получают клиенты.${N}"
echo -e "${Y}Можно пропустить (Enter), но тогда диагноз будет неполным.${N}"
read -rp $'Ссылка на подписку: ' SUBURL < /dev/tty

# ─────────────────────────────────────────────────────
hdr "1. Инфраструктура"
if systemctl is-active --quiet caddy; then ok "Caddy запущен"; else bad "Caddy не запущен"; PROBLEMS+=("Caddy не работает"); fi

LADDR=$(ss -tlnH "sport = :${XPORT}" 2>/dev/null | awk '{print $4}' | head -n1)
case "$LADDR" in
  "") bad "порт ${XPORT} не слушается — инбаунд не поднят"; PROBLEMS+=("Xray-инбаунд не работает") ;;
  127.0.0.1:*|"[::1]":*) ok "Xray слушает ${LADDR}" ;;
  *) bad "порт ${XPORT} слушается на ${LADDR} — инбаунд без TLS доступен снаружи"
     PROBLEMS+=("инбаунд слушает не на 127.0.0.1") ;;
esac

if command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -qx "$CT"; then
  M=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CT" 2>/dev/null)
  [[ "$M" == "host" ]] && ok "контейнер ${CT}: network_mode=host" \
    || { bad "network_mode=${M} (нужен host)"; PROBLEMS+=("Docker не в host-сети"); }
fi

# ─────────────────────────────────────────────────────
hdr "2. Матчер Caddy"
FIX=""; OLDMATCH=0
if [[ -n "$XPATH" ]] && grep -q "handle ${XPATH}/\* {" /etc/caddy/Caddyfile 2>/dev/null; then
  OLDMATCH=1
  warn "старый матчер — путь без слэша уходит в заглушку."
  # диагностика не меняет боевой конфиг без согласия
  read -rp "  Исправить Caddyfile и перезагрузить Caddy? [y/N]: " FIX < /dev/tty || FIX=""
  [[ "${FIX,,}" == y* ]] || PROBLEMS+=("старый матчер Caddy не исправлен")
fi
if [[ "${FIX,,}" == y* ]]; then
  cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"
  python3 - "$XPATH" <<'PYEOF'
import sys, re
xp = sys.argv[1]
f = '/etc/caddy/Caddyfile'
s = open(f).read()
old = f"handle {xp}/* {{"
new = f"@xhttp path {xp} {xp}/*\n\thandle @xhttp {{"
s = s.replace(old, new)
open(f, 'w').write(s)
PYEOF
  if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    systemctl reload caddy; ok "матчер исправлен, Caddy перезагружен"
  else
    bad "после правки Caddyfile невалиден — откатываю"
    cp "$(ls -t /etc/caddy/Caddyfile.bak.* | head -1)" /etc/caddy/Caddyfile
  fi
elif [[ $OLDMATCH -eq 0 ]]; then
  ok "матчер корректный"
fi

# ─────────────────────────────────────────────────────
hdr "3. Сайт-заглушка и проксирование"
for p in "/v1/health" "/"; do
  C=$(http_code "https://${DOMAIN}${p}")
  if [[ "$C" == "200" ]]; then ok "${p} → 200"; else bad "${p} → ${C}"; PROBLEMS+=("сайт недоступен"); fi
done
# заглушку узнаём по телу ответа: 404 умеет отдавать и сам Xray
for u in "${XPATH}" "${XPATH}/"; do
  if is_stub "https://${DOMAIN}${u}"; then
    bad "${u} → ответ API-заглушки (не в Xray)"; PROBLEMS+=("путь не проксируется")
  else
    ok "${u} → $(http_code "https://${DOMAIN}${u}" 6) (проксируется в Xray)"
  fi
done

# ─────────────────────────────────────────────────────
hdr "4. Разбор подписки — что получают клиенты"
UUID=""
if [[ -z "$SUBURL" ]]; then
  warn "ссылка не указана — пропускаю (это самая важная проверка!)"
else
  RAW=$(curl -sS --max-time 20 -H 'User-Agent: v2rayNG/1.8.0' "$SUBURL" 2>/dev/null)
  if [[ -z "$RAW" ]]; then
    bad "подписка не скачалась"; PROBLEMS+=("подписка недоступна")
  else
    # через файл, а не аргумент: большая подписка не влезает в лимит argv
    SUBTMP=$(mktemp)
    printf '%s' "$RAW" > "$SUBTMP"
    UUID=$(python3 - "$SUBTMP" "$DOMAIN" "$XPATH" <<'PYEOF'
import sys, base64, re, urllib.parse as up

raw, domain, xpath = open(sys.argv[1]).read().strip(), sys.argv[2], sys.argv[3]

# подписка может быть base64
text = raw
if 'vless://' not in raw:
    try:
        text = base64.b64decode(raw + '=' * (-len(raw) % 4)).decode('utf-8', 'ignore')
    except Exception:
        text = raw

links = re.findall(r'vless://[^\s"\'<>]+', text)
if not links:
    print("NOLINKS", file=sys.stderr)
    sys.exit(0)

C = {'g':'\033[0;32m','r':'\033[0;31m','y':'\033[1;33m','b':'\033[0;36m','n':'\033[0m'}
picked = ""
shown = 0

for L in links:
    try:
        rest = L[len('vless://'):]
        uuid, _, tail = rest.partition('@')
        hostport, _, q = tail.partition('?')
        query, _, tag = q.partition('#')
        host, _, port = hostport.partition(':')
        p = {k: v[0] for k, v in up.parse_qs(query).items()}
    except Exception:
        continue

    ntype = p.get('type', '')
    if ntype not in ('xhttp', 'splithttp'):
        continue

    shown += 1
    if shown > 2:
        break

    print(f"\n  {C['b']}── {up.unquote(tag) or 'без имени'} ──{C['n']}")
    print(f"     адрес     : {host}")

    prob = []
    if port == '443':
        print(f"     порт      : {C['g']}{port}{C['n']}")
    else:
        print(f"     порт      : {C['r']}{port}  ← ДОЛЖЕН БЫТЬ 443{C['n']}")
        prob.append(f"порт {port} вместо 443")

    sec = p.get('security', 'none')
    if sec == 'tls':
        print(f"     security  : {C['g']}{sec}{C['n']}")
    else:
        print(f"     security  : {C['r']}{sec}  ← ДОЛЖЕН БЫТЬ tls{C['n']}")
        prob.append(f"security={sec} вместо tls")

    pth = up.unquote(p.get('path', ''))
    if pth == xpath:
        print(f"     path      : {C['g']}{pth}{C['n']}")
    else:
        print(f"     path      : {C['r']}{pth}{C['n']}")
        print(f"                 {C['r']}ожидался: {xpath}{C['n']}")
        prob.append("path не совпадает")

    sni = p.get('sni', '')
    hst = up.unquote(p.get('host', ''))
    print(f"     sni       : {sni if sni==domain else C['r']+sni+' ← ожидался '+domain+C['n']}")
    print(f"     host      : {hst if hst==domain else C['r']+hst+' ← ожидался '+domain+C['n']}")
    if sni != domain: prob.append("sni не совпадает")
    if hst != domain: prob.append("host не совпадает")

    print(f"     type      : {ntype}")
    print(f"     mode      : {p.get('mode','(не задан)')}")
    print(f"     alpn      : {up.unquote(p.get('alpn','(не задан)'))}")

    if prob:
        print(f"\n     {C['r']}ПРОБЛЕМЫ: {', '.join(prob)}{C['n']}")
    else:
        print(f"\n     {C['g']}Все параметры корректны{C['n']}")

    if not picked:
        picked = uuid

print(f"\nUUID={picked}")
PYEOF
)
    rm -f "$SUBTMP"; SUBTMP=""
    echo "$UUID" | grep -v '^UUID=' || true
    UUID=$(echo "$UUID" | grep '^UUID=' | cut -d= -f2)
    [[ -n "$UUID" ]] && ok "UUID для теста извлечён: ${UUID:0:8}…"
  fi
fi

# ─────────────────────────────────────────────────────
hdr "5. Тест туннеля настоящим клиентом"
if [[ -z "$UUID" ]]; then
  read -rp "  UUID пользователя (или Enter — пропустить): " UUID < /dev/tty
fi

if [[ -z "$UUID" ]]; then
  warn "пропущен"
else
CLIENT_STARTED=1
docker exec "$CT" sh -c "$KILLER" 2>/dev/null || true
# конфиг с UUID пишется сразу в контейнер, на хосте копии не остаётся
docker exec -i "$CT" sh -c 'umask 077; cat > /tmp/xd.json' <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "tag":"s","listen":"127.0.0.1","port":${SOCKS},"protocol":"socks",
    "settings":{"udp":false,"auth":"noauth"} }],
  "outbounds": [{
    "tag":"p","protocol":"vless",
    "settings":{"vnext":[{"address":"${DOMAIN}","port":443,
      "users":[{"id":"${UUID}","encryption":"none"}]}]},
    "streamSettings":{
      "network":"xhttp","security":"tls",
      "tlsSettings":{"serverName":"${DOMAIN}","alpn":["h2"],"fingerprint":"chrome"},
      "xhttpSettings":{"host":"${DOMAIN}","path":"${XPATH}","mode":"auto"}
    }
  }]
}
EOF
docker exec -d "$CT" sh -c 'exec xray run -c /tmp/xd.json > /tmp/xd.log 2>&1'
UP=0; for _ in $(seq 1 15); do ss -tlnH "sport = :${SOCKS}" 2>/dev/null | grep -q . && { UP=1; break; }; sleep 1; done

if [[ $UP -eq 1 ]]; then
  IP=$(curl -sS --max-time 25 --socks5-hostname "127.0.0.1:${SOCKS}" https://api.ipify.org 2>/dev/null)
  if [[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    ok "ТУННЕЛЬ РАБОТАЕТ, внешний IP: ${IP}"
  else
    bad "туннель не поднялся"; PROBLEMS+=("туннель не работает")
    docker exec "$CT" sh -c 'tail -20 /tmp/xd.log' 2>/dev/null | sed 's/^/       /'
  fi
else
  bad "клиент не стартовал"
  docker exec "$CT" sh -c 'tail -20 /tmp/xd.log' 2>/dev/null | sed 's/^/       /'
fi
cleanup; CLIENT_STARTED=0
fi

# ─────────────────────────────────────────────────────
hdr "ИТОГ"
if [[ ${#PROBLEMS[@]} -eq 0 ]]; then
  echo -e "\n  ${G}Проблем на стороне сервера не найдено.${N}"
  echo -e "  Если клиенты всё ещё не подключаются — смотрите раздел 4:"
  echo -e "  там видно, что именно панель отдаёт в подписке.\n"
else
  echo -e "\n  ${R}Найдено проблем: ${#PROBLEMS[@]}${N}"
  for p in "${PROBLEMS[@]}"; do echo -e "    · ${p}"; done
  echo
fi

echo -e "${B}  Эталонные параметры хоста в панели:${N}"
echo -e "    Адрес       : ${DOMAIN}"
echo -e "    Порт        : ${G}443${N}"
echo -e "    Security    : ${G}TLS${N}"
echo -e "    SNI         : ${DOMAIN}"
echo -e "    Хост        : ${DOMAIN}"
echo -e "    Путь        : ${XPATH}"
echo -e "    ALPN        : h2"
echo
