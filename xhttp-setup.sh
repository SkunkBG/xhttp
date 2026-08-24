#!/usr/bin/env bash
#
#  XHTTP Media Stub — автоматическая установка
#  Caddy + медиа-API заглушка + TLS-фронт для XHTTP инбаунда Xray
#
#  Запуск:
#    bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/xhttp/main/xhttp-setup.sh)
#
#  Неинтерактивно:
#    DOMAIN=api.example.com EMAIL=me@mail.com bash <(curl -Ls ...)
#
set -euo pipefail

XRAY_PORT=8001
WEBROOT=/var/www/html
CADDYFILE=/etc/caddy/Caddyfile
OUTCONF=/root/xray-xhttp-config.json

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'; D='\033[2m'; N='\033[0m'
say()  { echo -e "${G}==>${N} $*"; }
info() { echo -e "${B} i ${N} $*"; }
warn() { echo -e "${Y} ! ${N} $*"; }
die()  { echo -e "${R} x ${N} $*" >&2; exit 1; }
ask()  { local p="$1" v="$2"; read -rp "$(echo -e "${B}?${N} $p")" "$v" < /dev/tty; }

banner() {
cat <<'EOF'

  ╔══════════════════════════════════════════════╗
  ║   XHTTP Media Stub  ·  Caddy + Xray  ·  TLS  ║
  ╚══════════════════════════════════════════════╝

EOF
}

# ──────────────────────────────────────────────
# 0. Проверки окружения
# ──────────────────────────────────────────────
banner
[[ $EUID -eq 0 ]] || die "Запустите от root:  sudo bash <(curl -Ls ...)"
[[ -r /etc/os-release ]] || die "Не удалось определить ОС"
. /etc/os-release
case "${ID}${ID_LIKE:-}" in
  *debian*|*ubuntu*) : ;;
  *) die "Поддерживаются только Debian / Ubuntu (обнаружено: ${PRETTY_NAME:-?})" ;;
esac

# ──────────────────────────────────────────────
# 1. Ввод параметров
# ──────────────────────────────────────────────
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
TOKEN="${TOKEN:-}"

if [[ -z "$DOMAIN" ]]; then
  ask "Домен (A-запись должна вести на этот сервер): " DOMAIN
fi
DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN// /}"
[[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "Некорректный домен: $DOMAIN"

if [[ -z "$EMAIL" ]]; then
  ask "Email для Let's Encrypt (Enter — пропустить): " EMAIL
fi
EMAIL="${EMAIL// /}"
if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$ ]]; then
  warn "Email выглядит некорректно, будет проигнорирован"
  EMAIL=""
fi

if [[ -z "$TOKEN" ]]; then
  ask "Секретный токен пути (Enter — сгенерировать): " TOKEN
fi
TOKEN="${TOKEN// /}"
[[ -z "$TOKEN" ]] && TOKEN=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
[[ "$TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || die "Токен: только буквы, цифры, - и _"

XPATH="/v1/stream/${TOKEN}"

echo
info "Домен      : ${DOMAIN}"
info "Email      : ${EMAIL:-<не указан>}"
info "XHTTP path : ${XPATH}"
info "Xray порт  : 127.0.0.1:${XRAY_PORT}"
echo

# ──────────────────────────────────────────────
# 2. Проверка DNS и занятых портов
# ──────────────────────────────────────────────
say "Проверяю DNS…"
MYIP=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)

if [[ -z "$RESOLVED" ]]; then
  warn "Домен ${DOMAIN} не резолвится — Let's Encrypt не выдаст сертификат."
  ask "Продолжить всё равно? [y/N]: " GO
  [[ "${GO,,}" == y* ]] || die "Отменено"
elif [[ -n "$MYIP" && "$RESOLVED" != "$MYIP" ]]; then
  warn "DNS → ${RESOLVED}, а IP сервера ${MYIP}"
  warn "Если домен проксируется через CDN — так и должно быть."
  warn "Иначе сертификат выпустить не удастся."
  ask "Продолжить? [y/N]: " GO
  [[ "${GO,,}" == y* ]] || die "Отменено"
else
  say "DNS в порядке: ${DOMAIN} → ${RESOLVED}"
fi

say "Проверяю порты 80/443…"
PORTBUSY=0
for p in 80 443; do
  if ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then
    OWNER=$(ss -tlnpH "sport = :$p" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -n1 || echo "?")
    if [[ "$OWNER" == "caddy" ]]; then
      info "Порт $p занят Caddy (это ок, переустановка)"
    else
      warn "Порт $p занят процессом: ${OWNER}"
      PORTBUSY=1
    fi
  fi
done
if [[ $PORTBUSY -eq 1 ]]; then
  echo
  warn "Caddy не сможет занять порт. Обычно это Xray с REALITY на 443."
  warn "Варианты: перенести REALITY на другой порт, либо ставить XHTTP на отдельный сервер."
  ask "Всё равно продолжить? [y/N]: " GO
  [[ "${GO,,}" == y* ]] || die "Отменено"
fi

# ──────────────────────────────────────────────
# 3. Установка Caddy
# ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive

if ! command -v caddy >/dev/null 2>&1; then
  say "Устанавливаю Caddy…"
  apt-get update -qq
  apt-get install -y -qq curl gnupg debian-keyring debian-archive-keyring apt-transport-https >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
  say "Caddy установлен: $(caddy version | head -n1)"
else
  say "Caddy уже установлен: $(caddy version | head -n1)"
fi

# ──────────────────────────────────────────────
# 4. Страница документации медиа-API
# ──────────────────────────────────────────────
say "Разворачиваю страницу документации…"
mkdir -p "$WEBROOT"
[[ -f "$WEBROOT/index.html" ]] && cp "$WEBROOT/index.html" "$WEBROOT/index.html.bak.$(date +%s)"

cat > "$WEBROOT/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lumen Media API — Documentation</title>
<meta name="description" content="Lumen Media API — programmable media ingest, transcoding and adaptive delivery.">
<meta name="robots" content="noindex, nofollow">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='7' fill='%235b8def'/><path d='M12 9l11 7-11 7z' fill='white'/></svg>">
<style>
:root{--bg:#0d1117;--panel:#161b22;--panel2:#1c2129;--line:#262d38;--tx:#c9d3e0;--tx2:#7d8899;--tx3:#5a6472;--acc:#5b8def;--grn:#3fb950;--org:#d29922;--pur:#a371f7;--mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--tx);font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;-webkit-font-smoothing:antialiased}
a{color:var(--acc);text-decoration:none}a:hover{text-decoration:underline}
code{font-family:var(--mono);font-size:.88em}
header{position:sticky;top:0;z-index:10;background:rgba(13,17,23,.85);backdrop-filter:blur(12px);border-bottom:1px solid var(--line)}
.hwrap{max-width:1120px;margin:0 auto;padding:0 24px;height:58px;display:flex;align-items:center;gap:28px}
.logo{display:flex;align-items:center;gap:9px;font-weight:600;font-size:15.5px;color:#fff}
.logo svg{width:23px;height:23px;flex:none}
nav{display:flex;gap:22px;font-size:14px}nav a{color:var(--tx2)}nav a:hover{color:var(--tx);text-decoration:none}
.pill{margin-left:auto;display:flex;align-items:center;gap:7px;font-size:12.5px;color:var(--tx2);border:1px solid var(--line);border-radius:20px;padding:4px 11px}
.dot{width:6px;height:6px;border-radius:50%;background:var(--grn);box-shadow:0 0 0 3px rgba(63,185,80,.15)}
.wrap{max-width:1120px;margin:0 auto;padding:0 24px}
.hero{padding:56px 0 40px;border-bottom:1px solid var(--line)}
.hero h1{font-size:33px;font-weight:650;color:#fff;letter-spacing:-.5px;margin-bottom:12px}
.hero p{font-size:16.5px;color:var(--tx2);max-width:680px}
.base{margin-top:26px;display:inline-flex;align-items:center;gap:11px;background:var(--panel);border:1px solid var(--line);border-radius:7px;padding:9px 14px;font-family:var(--mono);font-size:13.5px}
.base span{color:var(--tx3);font-family:inherit}
main{display:grid;grid-template-columns:194px 1fr;gap:46px;padding:38px 0 76px}
aside{position:sticky;top:82px;align-self:start;font-size:13.5px}
aside div{color:var(--tx3);text-transform:uppercase;font-size:11px;letter-spacing:.7px;margin:0 0 9px;font-weight:600}
aside a{display:block;color:var(--tx2);padding:5px 0}aside a:hover{color:var(--tx);text-decoration:none}
section{margin-bottom:52px;scroll-margin-top:82px}
h2{font-size:21px;font-weight:620;color:#fff;margin-bottom:9px;letter-spacing:-.2px}
h3{font-size:15px;font-weight:600;color:var(--tx);margin:26px 0 9px}
section>p{color:var(--tx2);margin-bottom:18px;max-width:720px}
.ep{border:1px solid var(--line);border-radius:9px;overflow:hidden;margin-bottom:16px;background:var(--panel)}
.ep-h{display:flex;align-items:center;gap:11px;padding:12px 15px;border-bottom:1px solid var(--line)}
.m{font-family:var(--mono);font-size:11.5px;font-weight:700;padding:3px 8px;border-radius:4px;letter-spacing:.4px}
.get{background:rgba(63,185,80,.13);color:var(--grn)}
.post{background:rgba(210,153,34,.13);color:var(--org)}
.del{background:rgba(163,113,247,.13);color:var(--pur)}
.ep-h code{color:var(--tx);font-size:13.5px}
.ep-b{padding:14px 15px;color:var(--tx2);font-size:14px}
.ep-b p{margin-bottom:10px}.ep-b p:last-child{margin-bottom:0}
pre{background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:14px 16px;overflow-x:auto;font-family:var(--mono);font-size:12.8px;line-height:1.6;color:var(--tx);margin:10px 0}
.k{color:var(--acc)}.s{color:var(--grn)}.n{color:var(--org)}.c{color:var(--tx3)}
table{width:100%;border-collapse:collapse;font-size:13.8px;margin:10px 0}
th{text-align:left;color:var(--tx3);font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:.6px;padding:0 12px 8px 0;border-bottom:1px solid var(--line)}
td{padding:9px 12px 9px 0;border-bottom:1px solid var(--line);color:var(--tx2);vertical-align:top}
td:first-child{color:var(--tx);font-family:var(--mono);font-size:12.8px;white-space:nowrap}
.req{color:var(--org);font-size:11px;font-family:var(--mono)}
.note{border-left:2px solid var(--acc);background:rgba(91,141,239,.06);padding:12px 16px;border-radius:0 7px 7px 0;font-size:14px;color:var(--tx2);margin:16px 0}
.note b{color:var(--tx);font-weight:600}
footer{border-top:1px solid var(--line);padding:26px 0;font-size:13px;color:var(--tx3)}
.fw{max-width:1120px;margin:0 auto;padding:0 24px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px}
footer a{color:var(--tx3)}
@media(max-width:840px){main{grid-template-columns:1fr;gap:0}aside{display:none}nav{display:none}.hero h1{font-size:26px}}
</style>
</head>
<body>
<header><div class="hwrap">
<div class="logo"><svg viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#5b8def"/><path d="M12 9l11 7-11 7z" fill="#fff"/></svg>Lumen Media API</div>
<nav><a href="#start">Quickstart</a><a href="#media">Media</a><a href="#stream">Streaming</a><a href="#errors">Errors</a></nav>
<div class="pill"><span class="dot"></span>All systems operational</div>
</div></header>

<div class="wrap"><div class="hero">
<h1>Media API Reference</h1>
<p>Programmable ingest, transcoding and adaptive delivery. REST over HTTPS, JSON responses, streaming endpoints for real-time session transport.</p>
<div class="base"><span>BASE URL</span> https://__DOMAIN__/v1</div>
</div></div>

<div class="wrap"><main>
<aside>
<div>Reference</div>
<a href="#start">Quickstart</a><a href="#auth">Authentication</a><a href="#media">Media objects</a>
<a href="#stream">Session streaming</a><a href="#formats">Formats</a><a href="#errors">Errors</a><a href="#limits">Rate limits</a>
</aside>
<div>

<section id="start">
<h2>Quickstart</h2>
<p>All requests are made over HTTPS to the base URL above. Responses are JSON encoded in UTF-8. The service exposes a health endpoint that requires no credentials.</p>
<pre><span class="c"># check service health</span>
curl https://__DOMAIN__/v1/health

<span class="c"># response</span>
{
  <span class="k">"status"</span>: <span class="s">"operational"</span>,
  <span class="k">"version"</span>: <span class="s">"1.4.2"</span>,
  <span class="k">"region"</span>: <span class="s">"eu-west"</span>
}</pre>
</section>

<section id="auth">
<h2>Authentication</h2>
<p>Authenticate with a bearer token issued per project. Tokens are scoped and may be restricted to specific media identifiers.</p>
<pre>Authorization: Bearer &lt;project_token&gt;</pre>
<div class="note"><b>Note.</b> Session tokens used by the streaming transport are single-purpose and rotate independently of project tokens. They are embedded in the request path rather than the header to remain compatible with intermediate caches.</div>
</section>

<section id="media">
<h2>Media objects</h2>
<p>A media object represents a single uploaded asset and its derived renditions.</p>
<div class="ep"><div class="ep-h"><span class="m get">GET</span><code>/v1/catalog</code></div>
<div class="ep-b"><p>Lists media objects available to the current project, most recent first.</p></div></div>
<div class="ep"><div class="ep-h"><span class="m get">GET</span><code>/v1/media/{media_id}</code></div>
<div class="ep-b"><p>Retrieves a single media object, including codec and rendition metadata.</p></div></div>
<div class="ep"><div class="ep-h"><span class="m post">POST</span><code>/v1/media</code></div>
<div class="ep-b"><p>Creates a media object and returns an ingest session for chunked upload.</p></div></div>
<div class="ep"><div class="ep-h"><span class="m del">DELETE</span><code>/v1/media/{media_id}</code></div>
<div class="ep-b"><p>Permanently removes a media object and all derived renditions.</p></div></div>
<pre>{
  <span class="k">"id"</span>: <span class="s">"med_8f2a91c4"</span>,
  <span class="k">"type"</span>: <span class="s">"video"</span>,
  <span class="k">"title"</span>: <span class="s">"Product Overview"</span>,
  <span class="k">"duration_s"</span>: <span class="n">184</span>,
  <span class="k">"codec"</span>: <span class="s">"h264"</span>,
  <span class="k">"resolution"</span>: <span class="s">"1920x1080"</span>,
  <span class="k">"status"</span>: <span class="s">"ready"</span>
}</pre>
</section>

<section id="stream">
<h2>Session streaming</h2>
<p>The streaming transport carries media payloads for an active session. It is designed for long-lived, low-latency delivery and supports both chunked upload and continuous download over the same session identifier.</p>
<div class="ep"><div class="ep-h"><span class="m post">POST</span><code>/v1/stream/{session_id}</code></div>
<div class="ep-b"><p>Uploads media chunks for the session. Accepts a continuous request body or a sequence of discrete chunk requests. Each chunk must not exceed the configured maximum payload size.</p></div></div>
<div class="ep"><div class="ep-h"><span class="m get">GET</span><code>/v1/stream/{session_id}</code></div>
<div class="ep-b"><p>Opens a persistent downstream channel for the session. The response body is delivered incrementally as segments become available and remains open for the lifetime of the session.</p></div></div>
<h3>Parameters</h3>
<table>
<tr><th>Name</th><th>Description</th></tr>
<tr><td>session_id <span class="req">required</span></td><td>Opaque session identifier returned when the session is created. Scoped to a single project and expires on close.</td></tr>
<tr><td>seq</td><td>Monotonic chunk sequence number. Used to reorder out-of-band deliveries.</td></tr>
<tr><td>Content-Type</td><td><code>application/octet-stream</code> for binary payloads, <code>text/event-stream</code> for incremental delivery.</td></tr>
</table>
<div class="note"><b>Keep-alive.</b> Downstream channels are held open and may remain idle between segments. Clients should not treat idle periods as disconnects; the server emits periodic padding frames to keep intermediaries from closing the connection.</div>
<h3>Limits</h3>
<table>
<tr><th>Property</th><th>Value</th></tr>
<tr><td>max_chunk_bytes</td><td>1000000</td></tr>
<tr><td>max_buffered_chunks</td><td>30</td></tr>
<tr><td>upstream_window_s</td><td>20–80</td></tr>
<tr><td>session_idle_timeout_s</td><td>300</td></tr>
</table>
</section>

<section id="formats">
<h2>Formats</h2>
<p>Supported containers and codecs for transcoding targets. Retrieve the current matrix from <code>/v1/formats</code>.</p>
<table>
<tr><th>Container</th><th>Video</th><th>Audio</th></tr>
<tr><td>mp4</td><td>h264, h265</td><td>aac, opus</td></tr>
<tr><td>webm</td><td>vp9, av1</td><td>opus</td></tr>
<tr><td>hls</td><td>h264</td><td>aac</td></tr>
</table>
</section>

<section id="errors">
<h2>Errors</h2>
<p>The API uses conventional HTTP status codes. Failures return a JSON body describing the error.</p>
<pre>{
  <span class="k">"error"</span>: {
    <span class="k">"type"</span>: <span class="s">"invalid_request_error"</span>,
    <span class="k">"code"</span>: <span class="s">"resource_not_found"</span>,
    <span class="k">"message"</span>: <span class="s">"The requested endpoint does not exist."</span>
  }
}</pre>
<table>
<tr><th>Status</th><th>Meaning</th></tr>
<tr><td>400</td><td>Malformed request or invalid parameters</td></tr>
<tr><td>401</td><td>Missing or invalid credentials</td></tr>
<tr><td>404</td><td>Resource or endpoint does not exist</td></tr>
<tr><td>413</td><td>Chunk exceeds max_chunk_bytes</td></tr>
<tr><td>429</td><td>Rate limit exceeded</td></tr>
<tr><td>5xx</td><td>Service error — retry with backoff</td></tr>
</table>
</section>

<section id="limits">
<h2>Rate limits</h2>
<p>Requests are limited per project token. Streaming sessions are excluded from request-count limits and are governed by concurrent session quota instead.</p>
<table>
<tr><th>Tier</th><th>Requests / min</th><th>Concurrent sessions</th></tr>
<tr><td>developer</td><td>120</td><td>4</td></tr>
<tr><td>standard</td><td>600</td><td>32</td></tr>
<tr><td>scale</td><td>3000</td><td>256</td></tr>
</table>
</section>

</div></main></div>
<footer><div class="fw">
<div>Lumen Media API · v1.4.2</div>
<div><a href="#start">Documentation</a> · <a href="/v1/health">Status</a></div>
</div></footer>
</body>
</html>
HTMLEOF

sed -i "s|__DOMAIN__|${DOMAIN}|g" "$WEBROOT/index.html"

printf 'User-agent: *\nDisallow: /v1/\n' > "$WEBROOT/robots.txt"

chown -R caddy:caddy "$WEBROOT" 2>/dev/null || true
say "Страница развёрнута: ${WEBROOT}/index.html"

# ──────────────────────────────────────────────
# 5. Caddyfile
# ──────────────────────────────────────────────
say "Настраиваю Caddy…"
mkdir -p /etc/caddy
[[ -f "$CADDYFILE" ]] && cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%s)" && info "Бэкап старого Caddyfile создан"

cat > "$CADDYFILE" <<'CADDYEOF'
__GLOBAL__
__DOMAIN__ {

	# ── XHTTP инбаунд: замаскирован под эндпоинт стриминга сессии ──
	handle __XPATH__/* {
		reverse_proxy 127.0.0.1:__XRAYPORT__ {
			flush_interval -1
			header_up X-Real-IP {remote_host}
		}
	}

	# ── Живые API-эндпоинты ──
	handle /v1/health {
		header Content-Type "application/json; charset=utf-8"
		header Cache-Control "no-store"
		respond `{"status":"operational","version":"1.4.2","region":"eu-west"}` 200
	}

	handle /v1/catalog {
		header Content-Type "application/json; charset=utf-8"
		header Cache-Control "public, max-age=300"
		respond `{"object":"list","has_more":false,"data":[{"id":"med_8f2a91c4","type":"video","title":"Product Overview","duration_s":184,"codec":"h264","resolution":"1920x1080"},{"id":"med_3b7e05da","type":"video","title":"Onboarding Walkthrough","duration_s":512,"codec":"h264","resolution":"1280x720"},{"id":"med_c14f97b2","type":"audio","title":"Release Notes 1.4","duration_s":327,"codec":"aac","bitrate_kbps":192}]}` 200
	}

	handle /v1/formats {
		header Content-Type "application/json; charset=utf-8"
		respond `{"object":"list","data":[{"container":"mp4","video":["h264","h265"],"audio":["aac","opus"]},{"container":"webm","video":["vp9","av1"],"audio":["opus"]},{"container":"hls","video":["h264"],"audio":["aac"]}]}` 200
	}

	handle /v1/* {
		header Content-Type "application/json; charset=utf-8"
		respond `{"error":{"type":"invalid_request_error","code":"resource_not_found","message":"The requested endpoint does not exist."}}` 404
	}

	# ── Документация и статика (robots.txt в том числе) ──
	handle {
		root * __WEBROOT__
		file_server
		encode gzip zstd
	}

	header {
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		Strict-Transport-Security "max-age=31536000"
		-Server
	}

	log {
		output discard
	}
}
CADDYEOF

if [[ -n "$EMAIL" ]]; then
  GLOBAL="{
	email ${EMAIL}
}
"
else
  GLOBAL=""
fi

python3 - "$CADDYFILE" "$GLOBAL" "$DOMAIN" "$XPATH" "$XRAY_PORT" "$WEBROOT" <<'PYEOF'
import sys
f, glob, dom, xpath, port, webroot = sys.argv[1:7]
s = open(f).read()
s = s.replace('__GLOBAL__\n', glob)
s = s.replace('__DOMAIN__', dom).replace('__XPATH__', xpath)
s = s.replace('__XRAYPORT__', port).replace('__WEBROOT__', webroot)
open(f, 'w').write(s)
PYEOF

say "Проверяю Caddyfile…"
caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
  || { caddy validate --config "$CADDYFILE" --adapter caddyfile || true; die "Caddyfile невалиден"; }

systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
say "Caddy перезапущен, жду выпуск сертификата…"

# ──────────────────────────────────────────────
# 6. Файрвол
# ──────────────────────────────────────────────
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
  say "Настраиваю UFW…"
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw deny  ${XRAY_PORT}/tcp >/dev/null 2>&1 || true
fi

# ──────────────────────────────────────────────
# 7. Конфиг Xray
# ──────────────────────────────────────────────
cat > "$OUTCONF" <<JSONEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "VLESS_XHTTP_MEDIA",
      "listen": "127.0.0.1",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "host": "${DOMAIN}",
          "path": "${XPATH}",
          "mode": "auto",
          "extra": {
            "xPaddingBytes": "100-1000",
            "noSSEHeader": false,
            "scMaxEachPostBytes": 1000000,
            "scMaxBufferedPosts": 30,
            "scStreamUpServerSecs": "20-80"
          }
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } },
    { "tag": "BLOCK", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "type": "field", "domain": ["geosite:private"], "outboundTag": "BLOCK" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "BLOCK" }
    ]
  },
  "policy": {
    "levels": { "0": { "connIdle": 300, "handshake": 4 } }
  }
}
JSONEOF

# ──────────────────────────────────────────────
# 8. Проверка
# ──────────────────────────────────────────────
say "Проверяю доступность…"
OK=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  CODE=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMAIN}/v1/health" 2>/dev/null || echo 000)
  [[ "$CODE" == "200" ]] && { OK=1; break; }
  sleep 3
done

echo
if [[ $OK -eq 1 ]]; then
  say "HTTPS работает, сертификат выпущен, /v1/health отвечает 200"
else
  warn "Не удалось подтвердить HTTPS автоматически."
  warn "Проверьте: curl -v https://${DOMAIN}/v1/health"
  warn "Логи:      journalctl -u caddy --no-pager -n 40"
fi

# ──────────────────────────────────────────────
# 9. Итог
# ──────────────────────────────────────────────
cat <<EOF

$(echo -e "${G}")────────────────────────────────────────────────────────────────
  УСТАНОВКА ЗАВЕРШЕНА
────────────────────────────────────────────────────────────────$(echo -e "${N}")

  Домен         : ${DOMAIN}
  XHTTP path    : ${XPATH}
  Xray слушает  : 127.0.0.1:${XRAY_PORT}
  Конфиг Xray   : ${OUTCONF}

$(echo -e "${B}")  ХОСТ В ПАНЕЛИ REMNAWAVE $(echo -e "${N}")

    Transport   : xhttp
    Security    : tls
    Port        : 443
    Host / SNI  : ${DOMAIN}
    Path        : ${XPATH}
    Mode        : auto
    ALPN        : h2
    Fingerprint : chrome

$(echo -e "${B}")  ДАЛЬШЕ $(echo -e "${N}")

    1. Откройте ${OUTCONF} и вставьте его в Xray-конфиг ноды
       (или добавьте inbound в существующий конфиг).
    2. Перезапустите ноду.
    3. Создайте хост в панели по параметрам выше.

$(echo -e "${B}")  ПРОВЕРКА $(echo -e "${N}")

    curl https://${DOMAIN}/v1/health
    curl https://${DOMAIN}/v1/catalog
    browser: https://${DOMAIN}/

$(echo -e "${Y}")  ВАЖНО $(echo -e "${N}")

    Путь ${XPATH}
    должен совпадать в Caddyfile и в конфиге Xray. Сохраните токен.

────────────────────────────────────────────────────────────────

EOF
