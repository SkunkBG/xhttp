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

[[ $EUID -eq 0 ]] || { echo "Запустите от root"; exit 1; }
CT="${CT:-remnanode}"; SOCKS=10809
PROBLEMS=()

echo -e "\n${B}╔════════════════════════════════════════╗"
echo -e "║   XHTTP Doctor — полная диагностика    ║"
echo -e "╚════════════════════════════════════════╝${N}"

# ── исходные данные ──
DOMAIN="${DOMAIN:-}"
[[ -z "$DOMAIN" ]] && read -rp $'\nДомен ноды: ' DOMAIN < /dev/tty

XPATH=$(grep -oP 'path /v1/stream/[A-Za-z0-9_-]+' /etc/caddy/Caddyfile 2>/dev/null | head -1 | awk '{print $2}')
[[ -z "$XPATH" ]] && XPATH=$(grep -oP '(?<=handle )/v1/stream/[A-Za-z0-9_-]+' /etc/caddy/Caddyfile 2>/dev/null | head -1)

echo -e "\n${Y}Ссылка на подписку любого юзера (панель → юзер → кнопка копирования${N}"
echo -e "${Y}подписки). Это ГЛАВНОЕ — покажет, что реально получают клиенты.${N}"
echo -e "${Y}Можно пропустить (Enter), но тогда диагноз будет неполным.${N}"
read -rp $'Ссылка на подписку: ' SUBURL < /dev/tty

# ─────────────────────────────────────────────────────
hdr "1. Инфраструктура"
systemctl is-active --quiet caddy && ok "Caddy запущен" || { bad "Caddy не запущен"; PROBLEMS+=("Caddy не работает"); }

if ss -tlnH "sport = :8001" 2>/dev/null | grep -q .; then
  ok "Xray слушает 127.0.0.1:8001"
else
  bad "порт 8001 не слушается — инбаунд не поднят"; PROBLEMS+=("Xray-инбаунд не работает")
fi

if command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -qx "$CT"; then
  M=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CT" 2>/dev/null)
  [[ "$M" == "host" ]] && ok "контейнер ${CT}: network_mode=host" \
    || { bad "network_mode=${M} (нужен host)"; PROBLEMS+=("Docker не в host-сети"); }
fi

# ─────────────────────────────────────────────────────
hdr "2. Автопочинка матчера Caddy"
if grep -q "handle ${XPATH}/\* {" /etc/caddy/Caddyfile 2>/dev/null; then
  warn "старый матчер — путь без слэша уходит в заглушку. Чиню…"
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
else
  ok "матчер уже корректный"
fi

# ─────────────────────────────────────────────────────
hdr "3. Сайт-заглушка и проксирование"
for p in "/v1/health" "/"; do
  C=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMAIN}${p}" 2>/dev/null || echo 000)
  [[ "$C" == "200" ]] && ok "${p} → 200" || { bad "${p} → ${C}"; PROBLEMS+=("сайт недоступен"); }
done
for u in "${XPATH}" "${XPATH}/"; do
  C=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMAIN}${u}" 2>/dev/null || echo 000)
  [[ "$C" == "404" ]] && { bad "${u} → 404 (в заглушку, не в Xray)"; PROBLEMS+=("путь не проксируется"); } \
                      || ok "${u} → ${C} (проксируется в Xray)"
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
    UUID=$(python3 - "$RAW" "$DOMAIN" "$XPATH" <<'PYEOF'
import sys, base64, re, urllib.parse as up

raw, domain, xpath = sys.argv[1], sys.argv[2], sys.argv[3]

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
cat > /tmp/xd.json <<EOF
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
KILLER='for p in /proc/[0-9]*; do [ -r "$p/cmdline" ] || continue; if tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -q xd.json; then kill "${p#/proc/}" 2>/dev/null; fi; done'
docker exec "$CT" sh -c "$KILLER" 2>/dev/null || true
docker exec -i "$CT" sh -c 'cat > /tmp/xd.json' < /tmp/xd.json
docker exec -d "$CT" sh -c 'exec xray run -c /tmp/xd.json > /tmp/xd.log 2>&1'
UP=0; for i in $(seq 1 15); do ss -tlnH "sport = :${SOCKS}" 2>/dev/null | grep -q . && { UP=1; break; }; sleep 1; done

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
docker exec "$CT" sh -c "$KILLER; rm -f /tmp/xd.json /tmp/xd.log" 2>/dev/null || true
rm -f /tmp/xd.json
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
