# Обратный прокси для Docker Compose

[![Documentation](https://github.com/foksk76/compose-caddy-https-proxy/actions/workflows/docs.yml/badge.svg)](https://github.com/foksk76/compose-caddy-https-proxy/actions/workflows/docs.yml)
[![Links](https://github.com/foksk76/compose-caddy-https-proxy/actions/workflows/links.yml/badge.svg)](https://github.com/foksk76/compose-caddy-https-proxy/actions/workflows/links.yml)

Этот репозиторий - шаблон для ситуации, когда приложение уже запущено через Docker Compose, но наружу торчит своим HTTP-портом. Цель: поставить перед ним Caddy, принимать трафик на `443`, а обращения на `80` и старый порт приложения уводить на HTTPS.

В качестве примера здесь используется Immich, но шаблон не завязан на него. Для другого приложения поменяйте имя службы, порты, адреса и сертификат.

## Для какой схемы

Основной сценарий - локальная сеть или NAT без белого IP и без публично доступного DNS-имени. В такой схеме Caddy получает готовые файлы `fullchain.pem` и `privkey.pem`: самоподписанный тестовый сертификат, сертификат от корпоративного CA или сертификат от другого внутреннего центра сертификации.

Если у сервиса есть публичное DNS-имя, DNS-записи указывают на сервер, а порты `80` и `443` доступны снаружи, можно использовать автоматический HTTPS Caddy через Let’s Encrypt. Тогда файлы в `certs/live/` не нужны: Caddy сам получает и продлевает сертификаты, а постоянный том `caddy-data` хранит ACME-состояние.

## Что получится

```text
браузер -> Caddy:443 -> приложение:BACKEND_PORT
браузер -> Caddy:80 -> редирект на HTTPS
браузер -> Caddy:LEGACY_HTTP_PORT -> редирект на HTTPS
```

Приложение продолжает слушать свой порт внутри сети Docker. Снаружи работает только Caddy.

## Что лежит в шаблоне

- `docker-compose.override.yml` добавляет службу `caddy` и убирает прямую публикацию порта приложения.
- `caddy/Caddyfile` настраивает HTTPS, обратный прокси и редиректы.
- `certs/live/<CERT_NAME>/fullchain.pem` и `privkey.pem` нужны только для ручного TLS.
- `.env.example` показывает переменные для своего окружения.

## Как двигаться

1. [Заполните переменные](#шаг-1-заполнить-переменные-окружения): имя сервиса, IP хоста, внутренний порт приложения и старый внешний порт.
2. [Подготовьте сертификат](#шаг-2-получить-сертификат): положите готовые `fullchain.pem` и `privkey.pem` или выберите автоматический HTTPS Caddy.
3. [Найдите службу приложения](#шаг-3-найти-службу-приложения): ту, у которой сейчас есть внешний `ports`.
4. [Скопируйте файлы шаблона](#шаг-4-положить-файлы-рядом-с-compose): рядом с основным `docker-compose.yml` приложения.
5. [Проверьте итоговый Compose](#шаг-5-проверить-compose): приложение должно остаться доступным внутри Docker, а наружу должен смотреть Caddy.
6. [Пересоздайте контейнеры](#шаг-6-запустить-или-пересоздать-caddy): сначала службу приложения, чтобы освободить старый порт, затем Caddy.
7. [Проверьте результат](#шаг-7-проверить-https-и-редиректы): HTTPS должен открываться, а `80` и старый порт должны редиректить на HTTPS.

Дальше те же шаги раскрыты как инструкция к действию.

## Шаг 1. Заполнить переменные окружения

Источник - файл `.env.example` из этого шаблона. Назначение - файл `.env` в каталоге приложения, рядом с основным `docker-compose.yml`.

Если у приложения ещё нет своего `.env`, скопируйте пример туда:

```bash
cp .env.example .env
```

Если вы запускаете команду из каталога приложения, а шаблон лежит в другом месте, укажите путь к источнику явно:

```bash
cp /path/to/compose-caddy-https-proxy/.env.example .env
```

Если у приложения уже есть свой `.env`, не затирайте его. Откройте `.env.example` из шаблона и добавьте показанные ниже переменные в существующий `.env` приложения.

```dotenv
# Имя сервиса.
# Для ручного TLS это может быть внутреннее имя.
# Для Let's Encrypt замените на публичное DNS-имя.
APP_FQDN=app.example.internal

# IP хоста, на котором опубликованы порты Caddy.
# Нужен для тестового самоподписанного сертификата и локальных проверок.
APP_IP=192.0.2.10

# Служба и порт приложения внутри Docker Compose.
BACKEND_SERVICE=app-server
BACKEND_PORT=2283

# Старый внешний HTTP-порт приложения, с которого нужен редирект.
LEGACY_HTTP_PORT=2283

# Имя каталога certs/live/<CERT_NAME> для ручного TLS.
# Для автоматического HTTPS Caddy не нужно.
CERT_NAME=app
```

| Переменная | Когда нужна | Зачем |
| --- | --- | --- |
| `APP_FQDN` | всегда | имя, по которому пользователи открывают сервис |
| `APP_IP` | ручной TLS и локальные проверки | IP хоста с портами `80`, `443` и `LEGACY_HTTP_PORT` |
| `BACKEND_SERVICE` | всегда | имя службы приложения в Compose-сети |
| `BACKEND_PORT` | всегда | внутренний HTTP-порт приложения |
| `LEGACY_HTTP_PORT` | если старый порт надо редиректить | внешний порт на хосте |
| `CERT_NAME` | только ручной TLS | каталог `certs/live/<CERT_NAME>/` |

`BACKEND_SERVICE` должен совпадать с именем службы приложения в `docker-compose.override.yml`. Для автоматического HTTPS Caddy `APP_FQDN` должен быть публичным DNS-именем, а `CERT_NAME` не нужен.

## Шаг 2. Получить сертификат

Выберите один из трёх вариантов.

### Вариант A. Самоподписанный сертификат для тестовой среды

Такой сертификат удобен для проверки шаблона, но браузеры не будут доверять ему автоматически.

```bash
set -a
. ./.env
set +a

mkdir -p "certs/live/$CERT_NAME"

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 30 \
  -keyout "certs/live/$CERT_NAME/privkey.pem" \
  -out "certs/live/$CERT_NAME/fullchain.pem" \
  -addext "subjectAltName=DNS:$APP_FQDN,IP:$APP_IP"

chmod 600 "certs/live/$CERT_NAME/privkey.pem"
```

OpenSSL интерактивно спросит поля сертификата. Для теста достаточно осмысленно заполнить `Common Name` именем сервиса:

```text
Generating a RSA private key
.............+++++
................................+++++
-----
Country Name (2 letter code) [AU]:RU
State or Province Name (full name) [Some-State]:Test
Locality Name (eg, city) []:Lab
Organization Name (eg, company) [Internet Widgits Pty Ltd]:Homelab
Organizational Unit Name (eg, section) []:Test
Common Name (e.g. server FQDN or YOUR name) []:app.example.internal
Email Address []:
```

На выходе должны появиться два файла:

```text
certs/live/app/fullchain.pem
certs/live/app/privkey.pem
```

### Вариант B. Сертификат предприятия

Создайте закрытый ключ и CSR, отправьте CSR в корпоративный центр сертификации, затем сохраните выданный сертификат и цепочку в `certs/live/$CERT_NAME/fullchain.pem`. Закрытый ключ из команды ниже должен остаться в `certs/live/$CERT_NAME/privkey.pem`.

```bash
set -a
. ./.env
set +a

mkdir -p "certs/live/$CERT_NAME"

openssl req -new -newkey rsa:2048 -sha256 -nodes \
  -keyout "certs/live/$CERT_NAME/privkey.pem" \
  -out "certs/live/$CERT_NAME/server.csr" \
  -addext "subjectAltName=DNS:$APP_FQDN,IP:$APP_IP"

chmod 600 "certs/live/$CERT_NAME/privkey.pem"
```

Ориентиры по выпуску:

- XCA: [Certificate Input Dialog](https://hohnstaedt.de/xca-doc/html/certificate-input.html)
- Microsoft CA: [Request a certificate using Certification Authority Web Enrollment](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/request-certificate-windows-server)

После выпуска сохраните файлы так:

```text
certs/live/$CERT_NAME/fullchain.pem   # сертификат сервиса, затем промежуточные CA, затем корневой CA
certs/live/$CERT_NAME/privkey.pem     # закрытый ключ, созданный вместе с CSR
```

### Вариант C. Автоматический HTTPS Caddy

Этот вариант подходит, если `APP_FQDN` - публичное DNS-имя, оно указывает на сервер, а порты `80` и `443` доступны снаружи. Файлы `fullchain.pem` и `privkey.pem` заранее не создаются: Caddy получит сертификат на шаге запуска и сохранит его в томе `caddy-data`.

Для этого в `docker-compose.override.yml` уберите `CERT_NAME` из `environment` и оба маунта `certs/live/...`, а в `caddy/Caddyfile` используйте публичное имя и уберите строку `tls ...`:

```caddyfile
https://app.example.com {
	encode zstd gzip
	reverse_proxy {$BACKEND_SERVICE}:{$BACKEND_PORT}
}
```

## Шаг 3. Найти службу приложения

Найдите каталог приложения, где лежит основной `docker-compose.yml`. Дальше команды из шагов 3-7 выполняются из этого каталога.

Откройте `docker-compose.yml` и найдите службу, которая сейчас публикует порт наружу.

```yaml
services:
  immich-server:
    ports:
      - "2283:2283"
    # --- snip ---
```

В `docker-compose.override.yml` переименуйте ключ службы и `depends_on` в это же имя:

```yaml
services:
  immich-server:
    ports: !reset []
    expose:
      - "${BACKEND_PORT:-2283}"

  caddy:
    depends_on:
      - immich-server
    # --- snip ---
```

Если приложение называется `photos`, оба места должны стать `photos`. Переменная `BACKEND_SERVICE` в `.env` должна совпадать с этим именем.

## Шаг 4. Положить файлы рядом с Compose

Скопируйте файлы шаблона в каталог приложения. В итоге рядом с основным Compose-файлом должны лежать:

```text
docker-compose.yml
docker-compose.override.yml
.env
caddy/Caddyfile
certs/live/<CERT_NAME>/fullchain.pem      # только ручной TLS
certs/live/<CERT_NAME>/privkey.pem        # только ручной TLS
```

Если у приложения уже есть `.env`, не заменяйте его целиком: добавьте в него переменные из шага 1.

Для ручного TLS Caddy ожидает именно эти пути:

```yaml
# docker-compose.override.yml
services:
  caddy:
    volumes:
      - ./certs/live/${CERT_NAME:-app}/fullchain.pem:/certs/live/${CERT_NAME:-app}/fullchain.pem:ro
      - ./certs/live/${CERT_NAME:-app}/privkey.pem:/certs/live/${CERT_NAME:-app}/privkey.pem:ro
      # --- snip ---
```

```caddyfile
# caddy/Caddyfile
:443 {
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	# --- snip ---
}
```

## Шаг 5. Проверить Compose

Проверьте, что Compose-файл собирается, приложение больше не публикует внешний `ports`, а Caddy публикует `80`, `443` и старый порт.

```bash
docker compose config
```

Если в проектном `.env` есть секреты приложения, не публикуйте полный вывод этой команды в открытом виде: Compose может показать подставленные значения.

## Шаг 6. Запустить или пересоздать Caddy

При первой миграции пересоздайте службу приложения, чтобы она освободила старый внешний порт, а затем запустите Caddy.

```bash
set -a
. ./.env
set +a

docker compose up -d --no-deps --force-recreate "$BACKEND_SERVICE"
docker compose up -d --no-deps --force-recreate caddy
docker compose ps "$BACKEND_SERVICE" caddy
```

Если Caddy уже работал и менялся только сертификат, Compose-файл или `Caddyfile`, можно пересоздать только Caddy:

```bash
docker compose up -d --no-deps --force-recreate caddy
docker compose ps caddy
```

Если менялся только `caddy/Caddyfile`, можно попробовать перезагрузку без пересоздания контейнера:

```bash
docker compose exec -T caddy \
  caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

## Шаг 7. Проверить HTTPS и редиректы

Для ручного TLS проверяйте HTTPS по имени и редиректы со старых HTTP-входов:

```bash
curl -k -I --resolve "$APP_FQDN:443:$APP_IP" "https://$APP_FQDN/"
curl -I --resolve "$APP_FQDN:80:$APP_IP" "http://$APP_FQDN/"
curl -I --resolve "$APP_FQDN:$LEGACY_HTTP_PORT:$APP_IP" \
  "http://$APP_FQDN:$LEGACY_HTTP_PORT/"
```

Для автоматического HTTPS Caddy проверяйте публичное имя без `-k`:

```bash
curl -I "https://$APP_FQDN/"
```

Ожидаемо: HTTPS отвечает `200` или другим нормальным кодом приложения, а HTTP-входы возвращают `301` на `https://...`.

## Проверки перед публикацией

Перед публикацией репозитория на GitHub запустите:

```bash
bash tests/docs.sh
```

Скрипт проверяет, что README ссылается на существующие шаги, changelog заполнен, старые OpenSSL-шаблоны не вернулись, а `.env`, рабочие сертификаты и закрытые ключи не попадут в публичные файлы. GitHub Actions дополнительно проверяет внешние ссылки в README и changelog через `.github/workflows/links.yml`.

Заметные изменения для пользователей фиксируются в `CHANGELOG.md`.
Условия использования описаны в `LICENSE`.

## Полный пример конфигурации

Ниже полный пример для ручного TLS. Для автоматического HTTPS Caddy уберите `CERT_NAME`, маунты `certs/live/...`, строку `tls ...` и используйте публичное имя в адресе сайта.

`docker-compose.override.yml`:

```yaml
services:
  # Переименуйте этот ключ службы и цель depends_on ниже в имя службы,
  # которая сейчас публикует порт приложения в базовом Compose-файле.
  # Пример для Immich: immich-server.
  immich-server:
    ports: !reset []
    expose:
      - "${BACKEND_PORT:-2283}"

  caddy:
    image: docker.io/library/caddy:2-alpine
    restart: always
    depends_on:
      - immich-server
    ports:
      - "80:80"
      - "443:443"
      - "${LEGACY_HTTP_PORT:-2283}:2283"
    environment:
      BACKEND_PORT: ${BACKEND_PORT:-2283}
      BACKEND_SERVICE: ${BACKEND_SERVICE:-app-server}
      # Ручной TLS: имя каталога certs/live/<CERT_NAME>.
      CERT_NAME: ${CERT_NAME:-app}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      # Ручной TLS: Caddy читает готовые fullchain.pem и privkey.pem.
      - ./certs/live/${CERT_NAME:-app}/fullchain.pem:/certs/live/${CERT_NAME:-app}/fullchain.pem:ro
      - ./certs/live/${CERT_NAME:-app}/privkey.pem:/certs/live/${CERT_NAME:-app}/privkey.pem:ro
      - caddy-data:/data
      - caddy-config:/config

volumes:
  caddy-data:
  caddy-config:
```

`caddy/Caddyfile`:

```caddyfile
{
	# Ручной TLS: редиректы описаны ниже явно.
	# Для автоматического HTTPS Caddy используйте публичное DNS-имя
	# и дайте Caddy самому управлять HTTPS.
	auto_https disable_redirects
}

http://:80 {
	redir https://{host}{uri} permanent
}

http://:2283 {
	redir https://{host}{uri} permanent
}

:443 {
	# Ручной TLS: Caddy читает готовые сертификат и ключ.
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	encode zstd gzip

	reverse_proxy {$BACKEND_SERVICE}:{$BACKEND_PORT}
}
```
