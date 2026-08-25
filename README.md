# XHTTP Media Stub

Автоматическая установка **медиа-API заглушки** и TLS-фронта на Caddy для XHTTP-инбаунда Xray (Remnawave или standalone).

Xray прячется за настоящим HTTPS: снаружи сервер выглядит как работающий media API с документацией, а секретный путь замаскирован под эндпоинт стриминга сессии.

## Установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/xhttp/main/xhttp-setup.sh)
```

Скрипт спросит домен, email для Let's Encrypt и токен пути (можно сгенерировать автоматически).

Неинтерактивно:

```bash
DOMAIN=api.example.com EMAIL=me@mail.com bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/xhttp/main/xhttp-setup.sh)
```

## Как это работает

```
Клиент → 443 (Caddy, настоящий сертификат Let's Encrypt)
             ├── /v1/stream/<токен>/*  → 127.0.0.1:8001  (Xray XHTTP)
             ├── /v1/health            → JSON
             ├── /v1/catalog           → JSON
             ├── /v1/formats           → JSON
             ├── /v1/*                 → 404 в формате API
             └── всё остальное         → документация API
```

Xray слушает только на `127.0.0.1` — наружу торчит один Caddy.

## Почему медиа-API

XHTTP генерирует специфичный трафик: длинные чанковые POST, долгоживущие GET с инкрементальной отдачей, паддинг-кадры при простое. Для обычного сайта это аномалия — для медиа-API норма.

В документации на заглушке этот паттерн описан как штатная работа сервиса:

- `POST /v1/stream/{session_id}` — чанковая загрузка, непрерывное тело запроса
- `GET /v1/stream/{session_id}` — постоянный нисходящий канал, инкрементальная отдача
- блок Keep-alive — «сервер отправляет периодические паддинг-кадры»

Лимиты в документации совпадают с реальными параметрами XHTTP:

| В документации | Параметр Xray |
| --- | --- |
| `max_chunk_bytes: 1000000` | `scMaxEachPostBytes` |
| `max_buffered_chunks: 30` | `scMaxBufferedPosts` |
| `upstream_window_s: 20–80` | `scStreamUpServerSecs` |
| `session_idle_timeout_s: 300` | `policy.connIdle` |

Секретный путь `/v1/stream/<токен>` неотличим от документированного `/v1/stream/{session_id}`.

## Что делает скрипт

1. Проверяет ОС, DNS, занятость портов 80/443
2. Устанавливает Caddy (если не установлен)
3. Разворачивает страницу документации в `/var/www/html`
4. Пишет `/etc/caddy/Caddyfile` (бэкап старого создаётся)
5. Выпускает сертификат Let's Encrypt
6. Настраивает UFW: открывает 80/443, закрывает 8001
7. Генерирует готовый конфиг Xray в `/root/xray-xhttp-config.json`
8. Проверяет, что HTTPS поднялся

## После установки

Вставьте `/root/xray-xhttp-config.json` в конфиг ноды и создайте хост в панели:

| Поле | Значение |
| --- | --- |
| Transport | `xhttp` |
| Security | `tls` |
| Port | `443` |
| Host / SNI | ваш домен |
| Path | `/v1/stream/<токен>` |
| Mode | `auto` |
| ALPN | `h2` |
| Fingerprint | `chrome` |

Путь обязан совпадать в Caddyfile и в конфиге Xray.

## Проверка

```bash
curl https://ДОМЕН/v1/health       # {"status":"operational",...}
curl https://ДОМЕН/v1/catalog      # список медиа
curl -I https://ДОМЕН/v1/nope      # 404 в формате API
curl -I --http2 https://ДОМЕН/     # HTTP/2
```

## Работа за CDN

Настоящий сертификат позволяет спрятать сервер за Cloudflare — клиенты идут на IP CDN, реальный IP сервера в соединении не участвует. Это решает проблему заблокированного IP без его смены.

1. Домен на NS Cloudflare
2. A-запись, оранжевое облако включено
3. SSL/TLS mode → **Full (strict)**

Если через CDN не пробивается — смените `mode` с `auto` на `packet-up` (самый совместимый режим).

**Не включайте CDN на домене, который используется как SNI для REALITY** — REALITY требует прямого соединения.

## Требования

- Debian / Ubuntu, root
- Домен с A-записью на сервер
- Свободные порты 80 и 443

Если 443 занят Xray с REALITY — перенесите REALITY на другой порт либо ставьте XHTTP на отдельный сервер. Скрипт предупредит.

## Файлы

| Путь | Назначение |
| --- | --- |
| `/var/www/html/index.html` | Страница документации |
| `/etc/caddy/Caddyfile` | Конфиг Caddy |
| `/root/xray-xhttp-config.json` | Готовый конфиг Xray |

## Кастомизация

Замените `Lumen Media API` на своё название — имя не должно совпадать с реально существующим сервисом.

```bash
nano /var/www/html/index.html
systemctl reload caddy
```

## Удаление

```bash
systemctl stop caddy && systemctl disable caddy
apt remove caddy -y
rm -rf /var/www/html /etc/caddy /root/xray-xhttp-config.json
```

## Источники

- [XHTTP: Beyond REALITY — Discussion #4113](https://github.com/XTLS/Xray-core/discussions/4113)
- [Project X — Конфигурация транспорта](https://xtls.github.io/ru/config/transports/)

MIT

## Диагностика

Если сайт открывается, но VPN не подключается:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SkunkBG/xhttp/main/xhttp-diag.sh)
```

Скрипт проверит Caddy, порты, сетевой режим Docker-контейнера ноды, проксирование XHTTP-пути и доступность Xray напрямую.

### Частые причины

| Симптом | Причина |
| --- | --- |
| Путь отдаёт **404** | Caddy не проксирует путь в Xray — проверьте совпадение path |
| Путь отдаёт **502** | Caddy проксирует, но Xray-инбаунд не поднят |
| Никто не слушает **8001** | Конфиг Xray не применён на ноде |
| Контейнер не в `network_mode: host` | `127.0.0.1` в контейнере ≠ `127.0.0.1` на хосте |
