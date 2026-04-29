# Обратный прокси для Docker Compose

Этот репозиторий - шаблон для ситуации, когда приложение уже запущено через Docker Compose, но наружу торчит своим HTTP-портом. Цель простая: поставить перед ним Caddy, принимать трафик на `443`, а обращения на `80` и старый порт приложения уводить на HTTPS.

В качестве примера здесь используется Immich, но сам шаблон не завязан на него. Для другого приложения надо поменять имя службы, порты, адреса и выпустить сертификат под свои имена.

## Для какой схемы

Основной сценарий этого шаблона - Caddy в локальной сети или за NAT, без белого IP и без публично доступного DNS-имени. В такой схеме внешний центр сертификации не сможет обычным способом проверить ваш внутренний узел, поэтому используется локальный CA: вы сами выпускаете корневой сертификат, доверяете ему на своих устройствах и кладёте Caddy готовые `fullchain.pem` и `privkey.pem`.

Если у сервиса есть публичное DNS-имя, DNS-записи указывают на сервер, а порты `80` и `443` доступны снаружи, проще использовать штатный путь Caddy: автоматический HTTPS через публичный ACME CA, обычно Let’s Encrypt. Тогда OpenSSL-конфиги, локальный CA и файлы в `certs/live/` не нужны: Caddy сам получает и продлевает сертификаты, а постоянное хранилище `caddy-data` сохраняет его ACME-состояние.

Есть промежуточный вариант: публичный домен без открытого входа снаружи, но с DNS-провайдером, у которого есть API. В таком случае Let’s Encrypt можно использовать через DNS-01, но этот репозиторий держит фокус на более прямой локальной схеме с собственным CA.

## Что получится

До:

```text
браузер -> приложение:старый_порт
```

После:

```text
браузер -> Caddy:443 -> приложение:BACKEND_PORT
браузер -> Caddy:80 -> редирект на HTTPS
браузер -> Caddy:LEGACY_HTTP_PORT -> редирект на HTTPS
```

Приложение продолжает слушать свой порт внутри сети Docker. Снаружи работает только Caddy.

## Что лежит в шаблоне

- `docker-compose.override.yml` добавляет службу `caddy` и убирает прямую публикацию порта приложения.
- `caddy/Caddyfile` настраивает HTTPS, обратный прокси и редиректы.
- `certs/openssl/root-ca.cnf` нужен только для режима с локальным CA.
- `certs/openssl/server.cnf` нужен только для сертификата приложения от локального CA.
- `certs/live/<CERT_NAME>/fullchain.pem` и `privkey.pem` нужны только для локального CA / ручного TLS.
- `.env.example` показывает переменные для своего окружения.
- `.gitignore` защищает от случайной публикации `.env`, ключей и рабочих сертификатов.

## Быстрый маршрут

1. Найти в основном `docker-compose.yml` службу приложения, которая сейчас публикует порт наружу.
2. Вписать это имя службы в `docker-compose.override.yml`.
3. Скопировать `.env.example` в `.env` и заполнить общие переменные.
4. Для локального CA подготовить сертификат приложения и закрытый ключ; для Let’s Encrypt переключить Caddy на автоматический HTTPS.
5. Проверить итоговый Compose-файл.
6. Запустить или пересоздать Caddy.
7. Проверить HTTPS и редиректы.
8. Перед публикацией убедиться, что реальные адреса, ключи и сертификаты не попадут в репозиторий.

Дальше те же шаги раскрыты как инструкция к действию.

## Шаг 1. Найти службу приложения

Этот шаг одинаковый для локального CA и для Let’s Encrypt: Caddy должен понимать, в какую службу Compose отправлять трафик. Сначала откройте основной `docker-compose.yml` приложения и найдите службу, которая сейчас публикует порт наружу через `ports`.

Для Immich это обычно служба вида:

```yaml
services:
  immich-server:
    ports:
      - "2283:2283"
    # --- snip ---
```

В `docker-compose.override.yml` имя этой службы должно быть записано буквально. Полный пример: [Полный пример конфигурации](#полный-пример-конфигурации).

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

Если переносите шаблон на другое приложение, переименуйте оба места:

- ключ службы верхнего уровня, например `immich-server:`;
- запись в `depends_on` у службы `caddy`.

Если приложение называется `photos`, то оба места должны стать `photos`. Это правится руками, потому что Docker Compose склеивает службы по имени ключа, а не по переменной из `.env`.

На этом этапе нужны переменные:

| Переменная | Где участвует |
| --- | --- |
| `BACKEND_SERVICE` | имя той же службы приложения для Caddy |
| `BACKEND_PORT` | внутренний порт приложения в сети Docker |
| `LEGACY_HTTP_PORT` | старый внешний порт, с которого нужен редирект |

Важно: `BACKEND_SERVICE` в `.env` должен совпадать с именем службы, которое вы только что прописали в `docker-compose.override.yml`.

`LEGACY_HTTP_PORT` - это порт на хосте. Внутри контейнера Caddy в этом шаблоне слушает `2283`, а Compose пробрасывает внешний `LEGACY_HTTP_PORT` на этот внутренний порт.

Где это используется:

```yaml
# docker-compose.override.yml
services:
  immich-server:
    # --- snip ---
    expose:
      - "${BACKEND_PORT:-2283}"

  caddy:
    depends_on:
      - immich-server
    ports:
      - "${LEGACY_HTTP_PORT:-2283}:2283"
    environment:
      BACKEND_SERVICE: ${BACKEND_SERVICE:-app-server}
      BACKEND_PORT: ${BACKEND_PORT:-2283}
      # --- snip ---
```

```caddyfile
# caddy/Caddyfile
:443 {
	# --- snip ---
	reverse_proxy {$BACKEND_SERVICE}:{$BACKEND_PORT}
}
```

## Шаг 2. Заполнить `.env`

Скопируйте пример:

```bash
cp .env.example .env
```

Если у приложения уже есть свой `.env`, не затирайте его. Просто добавьте в существующий файл переменные из `.env.example`.

Минимальный набор:

```dotenv
# Общее для локального CA и Let's Encrypt.
# Для Let's Encrypt здесь должно быть публичное DNS-имя.
APP_FQDN=app.example.internal

BACKEND_SERVICE=app-server
BACKEND_PORT=2283

LEGACY_HTTP_PORT=2283

# Локальный CA / ручной TLS.
APP_HOST=app
APP_IP=192.0.2.10

CERT_NAME=app
CERT_ORG=Homelab
CERT_OU=Application
LOCAL_CA_CN="Homelab Local CA"
LOCAL_CA_OU="Local CA"
```

На этом этапе сначала нужны общие переменные для маршрута до приложения. Переменные сертификатов нужны только для локального CA / ручного TLS.

| Группа | Переменные | Зачем |
| --- | --- | --- |
| Общее для обоих режимов | `BACKEND_SERVICE`, `BACKEND_PORT`, `LEGACY_HTTP_PORT` | нужны Compose и Caddy |
| Локальный CA | `APP_HOST`, `APP_FQDN`, `APP_IP` | попадут в SAN сертификата приложения и проверки |
| Локальный CA | `CERT_NAME`, `CERT_ORG`, `CERT_OU`, `LOCAL_CA_CN`, `LOCAL_CA_OU` | нужны OpenSSL и путям к `certs/live/` |
| Let’s Encrypt | `APP_FQDN` | публичное DNS-имя, которое Caddy указывает в адресе сайта |

`APP_HOST` - короткое имя в локальной сети.  
`APP_FQDN` - полное имя.  
`APP_IP` - IP-адрес узла, на котором опубликованы порты `80`, `443` и старый порт приложения.  
`CERT_NAME` - имя каталога внутри `certs/live/`; нужно только для локального CA / ручного TLS.

Если смотреть по конфигам, общие переменные кормят Compose и Caddy, а переменные локального CA - OpenSSL и пути к готовым сертификатам:

```yaml
# docker-compose.override.yml
services:
  caddy:
    # --- snip ---
    ports:
      - "80:80"
      - "443:443"
      - "${LEGACY_HTTP_PORT:-2283}:2283"
    environment:
      BACKEND_PORT: ${BACKEND_PORT:-2283}
      BACKEND_SERVICE: ${BACKEND_SERVICE:-app-server}
      # Локальный CA / ручной TLS.
      CERT_NAME: ${CERT_NAME:-app}
    volumes:
      # Локальный CA / ручной TLS.
      - ./certs/live/${CERT_NAME:-app}/fullchain.pem:/certs/live/${CERT_NAME:-app}/fullchain.pem:ro
      - ./certs/live/${CERT_NAME:-app}/privkey.pem:/certs/live/${CERT_NAME:-app}/privkey.pem:ro
      # --- snip ---
```

```caddyfile
# caddy/Caddyfile
:443 {
	# Локальный CA / ручной TLS.
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	# --- snip ---
	reverse_proxy {$BACKEND_SERVICE}:{$BACKEND_PORT}
}
```

```ini
# certs/openssl/server.cnf
# Локальный CA / ручной TLS.
[dn]
CN = $ENV::APP_FQDN
O = $ENV::CERT_ORG
OU = $ENV::CERT_OU

# --- snip ---

[alt_names]
DNS.1 = $ENV::APP_HOST
DNS.2 = $ENV::APP_FQDN
IP.1 = $ENV::APP_IP
```

```ini
# certs/openssl/root-ca.cnf
# Локальный CA / ручной TLS.
[dn]
CN = $ENV::LOCAL_CA_CN
O = $ENV::CERT_ORG
OU = $ENV::LOCAL_CA_OU

# --- snip ---
```

## Шаг 3. Положить файлы рядом с Compose

Файлы шаблона должны лежать рядом с основным Compose-файлом приложения:

```text
docker-compose.yml
docker-compose.override.yml
.env
caddy/Caddyfile
certs/openssl/root-ca.cnf                 # локальный CA
certs/openssl/server.cnf                  # локальный CA
certs/live/<CERT_NAME>/fullchain.pem      # локальный CA / ручной TLS
certs/live/<CERT_NAME>/privkey.pem        # локальный CA / ручной TLS
```

На этом этапе нужна переменная:

| Переменная | Где участвует |
| --- | --- |
| `CERT_NAME` | имя каталога `certs/live/<CERT_NAME>/`; нужно только для локального CA / ручного TLS |

Caddy ожидает именно эти файлы:

```text
certs/live/$CERT_NAME/fullchain.pem
certs/live/$CERT_NAME/privkey.pem
```

Для Let’s Encrypt через автоматический HTTPS эти файлы не готовят: Caddy сам держит сертификаты и состояние ACME в своём постоянном томе.

Эти пути состыкованы в двух местах:

```yaml
# docker-compose.override.yml
services:
  caddy:
    # --- snip ---
    volumes:
      # Локальный CA / ручной TLS.
      - ./certs/live/${CERT_NAME:-app}/fullchain.pem:/certs/live/${CERT_NAME:-app}/fullchain.pem:ro
      - ./certs/live/${CERT_NAME:-app}/privkey.pem:/certs/live/${CERT_NAME:-app}/privkey.pem:ro
      # --- snip ---
```

```caddyfile
# caddy/Caddyfile
:443 {
	# Локальный CA / ручной TLS.
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	# --- snip ---
}
```

## Шаг 4. Подготовить сертификаты

Этот шаг нужен для локального CA / ручного TLS. Если используете Let’s Encrypt через автоматический HTTPS Caddy, этот шаг пропускается: вместо выпуска локального сертификата Caddy должен быть настроен на публичное DNS-имя.

Для локального CA загрузите переменные в текущую оболочку:

```bash
set -a
. ./.env
set +a
```

На этом этапе нужны переменные локального CA:

| Переменная | Где участвует |
| --- | --- |
| `APP_HOST` | SAN: короткое имя |
| `APP_FQDN` | CN и SAN: полное имя |
| `APP_IP` | SAN: IP-адрес |
| `CERT_NAME` | имена каталогов и файлов |
| `CERT_ORG` | поле организации в сертификатах |
| `CERT_OU` | подразделение в сертификате приложения |
| `LOCAL_CA_CN` | имя локального центра сертификации |
| `LOCAL_CA_OU` | подразделение локального центра сертификации |

OpenSSL забирает эти значения прямо из окружения:

```ini
# certs/openssl/server.cnf
# Локальный CA / ручной TLS.
[dn]
CN = $ENV::APP_FQDN
O = $ENV::CERT_ORG
OU = $ENV::CERT_OU

# --- snip ---

[alt_names]
DNS.1 = $ENV::APP_HOST
DNS.2 = $ENV::APP_FQDN
IP.1 = $ENV::APP_IP
```

```ini
# certs/openssl/root-ca.cnf
# Локальный CA / ручной TLS.
[dn]
CN = $ENV::LOCAL_CA_CN
O = $ENV::CERT_ORG
OU = $ENV::LOCAL_CA_OU

# --- snip ---
```

Если локального центра сертификации ещё нет, можно выпустить тестовый локальный CA:

```bash
mkdir -p certs/ca/private "certs/live/$CERT_NAME"

openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
  -keyout "certs/ca/private/$CERT_NAME-root-ca.key" \
  -out "certs/ca/$CERT_NAME-root-ca.crt" \
  -config certs/openssl/root-ca.cnf
```

Если CA уже есть, используйте его сертификат и закрытый ключ. Новый CA выпускать не надо.

Сертификат приложения:

```bash
openssl req -newkey rsa:4096 -nodes \
  -keyout "certs/live/$CERT_NAME/privkey.pem" \
  -out "certs/live/$CERT_NAME/server.csr" \
  -config certs/openssl/server.cnf

openssl x509 -req \
  -in "certs/live/$CERT_NAME/server.csr" \
  -CA "certs/ca/$CERT_NAME-root-ca.crt" \
  -CAkey "certs/ca/private/$CERT_NAME-root-ca.key" \
  -CAcreateserial \
  -out "certs/live/$CERT_NAME/cert.pem" \
  -days 825 -sha256 \
  -extensions v3_server_cert \
  -extfile certs/openssl/server.cnf

cat "certs/live/$CERT_NAME/cert.pem" "certs/ca/$CERT_NAME-root-ca.crt" \
  > "certs/live/$CERT_NAME/fullchain.pem"

chmod 600 "certs/live/$CERT_NAME/privkey.pem" "certs/ca/private/$CERT_NAME-root-ca.key"
```

`fullchain.pem` должен идти в таком порядке:

```text
-----BEGIN CERTIFICATE-----
сертификат приложения для APP_HOST / APP_FQDN / APP_IP
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
сертификат локального центра сертификации
-----END CERTIFICATE-----
```

`privkey.pem` должен быть закрытым ключом. Например:

```text
-----BEGIN RSA PRIVATE KEY-----
закрытый ключ в формате PEM
-----END RSA PRIVATE KEY-----
```

или:

```text
-----BEGIN PRIVATE KEY-----
закрытый ключ в формате PEM
-----END PRIVATE KEY-----
```

Если туда случайно положить `BEGIN PUBLIC KEY`, Caddy не запустится.

SAN в сертификате приложения должен включать:

- `DNS:$APP_HOST`;
- `DNS:$APP_FQDN`;
- `IP:$APP_IP`.

Проверка:

```bash
openssl x509 -in "certs/live/$CERT_NAME/fullchain.pem" -noout -ext subjectAltName
```

Правильный кусок вывода:

```text
X509v3 Subject Alternative Name:
    DNS:app, DNS:app.example.internal, IP Address:192.0.2.10
```

В реальном выводе должны быть ваши значения из `.env`.

## Шаг 5. Проверить цепочку и ключ

Этот шаг нужен только для локального CA / ручного TLS. При Let’s Encrypt Caddy сам получает, хранит и продлевает сертификаты.

На этом этапе нужна переменная:

| Переменная | Где участвует |
| --- | --- |
| `CERT_NAME` | путь к `fullchain.pem` и `privkey.pem`; нужно только для локального CA / ручного TLS |

Проверяется та же пара файлов, которую Caddy получает из конфига:

```caddyfile
# caddy/Caddyfile
:443 {
	# Локальный CA / ручной TLS.
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	# --- snip ---
}
```

Проверить состав PEM-файлов:

```bash
grep -n "BEGIN\|END" "certs/live/$CERT_NAME/fullchain.pem" "certs/live/$CERT_NAME/privkey.pem"
```

Ожидаемо:

```text
certs/live/app/fullchain.pem:1:-----BEGIN CERTIFICATE-----
certs/live/app/fullchain.pem:<номер строки>:-----END CERTIFICATE-----
certs/live/app/fullchain.pem:<номер строки>:-----BEGIN CERTIFICATE-----
certs/live/app/fullchain.pem:<номер строки>:-----END CERTIFICATE-----
certs/live/app/privkey.pem:1:-----BEGIN PRIVATE KEY-----
certs/live/app/privkey.pem:<номер строки>:-----END PRIVATE KEY-----
```

Проверить первый сертификат в цепочке:

```bash
openssl x509 -in "certs/live/$CERT_NAME/fullchain.pem" \
  -noout -subject -issuer -dates -ext subjectAltName
```

Проверить, что закрытый ключ подходит к сертификату:

```bash
openssl x509 -in "certs/live/$CERT_NAME/fullchain.pem" -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256

openssl pkey -in "certs/live/$CERT_NAME/privkey.pem" -pubout -outform DER \
  | openssl dgst -sha256
```

Хэши должны совпасть.

Проверить цепочку:

```bash
openssl verify -show_chain \
  -CAfile <(awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n==2{print}' "certs/live/$CERT_NAME/fullchain.pem") \
  <(awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n==1{print}' "certs/live/$CERT_NAME/fullchain.pem")
```

Ожидаемо:

```text
/dev/fd/63: OK
Chain:
depth=0: CN=app.example.internal, O=Homelab, OU=Application (untrusted)
depth=1: CN=Homelab Local CA, O=Homelab, OU=Local CA
```

## Шаг 6. Проверить Compose

Для локального CA Compose должен увидеть маунты `fullchain.pem` и `privkey.pem`. Для Let’s Encrypt эти маунты обычно убирают, но том `caddy-data` оставляют постоянным, потому что там Caddy хранит ACME-состояние и сертификаты.

На этом этапе нужны переменные:

| Переменная | Где участвует |
| --- | --- |
| `BACKEND_SERVICE` | Caddy проксирует в эту службу |
| `BACKEND_PORT` | Caddy проксирует на этот порт |
| `LEGACY_HTTP_PORT` | внешний старый порт, который будет редиректить на HTTPS |
| `CERT_NAME` | только локальный CA: пути к сертификату и ключу в volume |

Эти строки должны нормально собраться после подстановки `.env`:

```yaml
# docker-compose.override.yml
services:
  caddy:
    # --- snip ---
    ports:
      - "80:80"
      - "443:443"
      - "${LEGACY_HTTP_PORT:-2283}:2283"
    environment:
      BACKEND_PORT: ${BACKEND_PORT:-2283}
      BACKEND_SERVICE: ${BACKEND_SERVICE:-app-server}
      # Локальный CA / ручной TLS.
      CERT_NAME: ${CERT_NAME:-app}
    volumes:
      # Локальный CA / ручной TLS.
      - ./certs/live/${CERT_NAME:-app}/fullchain.pem:/certs/live/${CERT_NAME:-app}/fullchain.pem:ro
      - ./certs/live/${CERT_NAME:-app}/privkey.pem:/certs/live/${CERT_NAME:-app}/privkey.pem:ro
      # --- snip ---
```

```caddyfile
# caddy/Caddyfile
:443 {
	# Локальный CA / ручной TLS.
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	# --- snip ---
	reverse_proxy {$BACKEND_SERVICE}:{$BACKEND_PORT}
}
```

Проверка:

```bash
docker compose config
```

Команда должна отработать без ошибки. Если в проектном `.env` есть секреты приложения, не публикуйте полный вывод этой команды в открытом виде: Compose может показать подставленные значения.

Полезно отдельно проверить, что в итоговом файле у службы приложения больше нет внешнего `ports`, а есть `expose`. Это означает, что приложение доступно Caddy внутри сети Docker, но не торчит наружу напрямую.

## Шаг 7. Запустить или пересоздать Caddy

В режиме локального CA Caddy читает готовые файлы сертификата. В режиме Let’s Encrypt Caddy должен быть настроен на публичное DNS-имя и сам выполнит ACME-выпуск при старте или перезагрузке.

На этом этапе нужны переменные:

| Переменная | Где участвует |
| --- | --- |
| `BACKEND_SERVICE` | цель `reverse_proxy` |
| `BACKEND_PORT` | порт цели `reverse_proxy` |
| `CERT_NAME` | только локальный CA: сертификат и ключ для TLS |
| `LEGACY_HTTP_PORT` | публикация старого порта на хосте |

При запуске Compose передаёт эти значения в контейнер Caddy:

```yaml
# docker-compose.override.yml
services:
  caddy:
    # --- snip ---
    ports:
      - "80:80"
      - "443:443"
      - "${LEGACY_HTTP_PORT:-2283}:2283"
    environment:
      BACKEND_PORT: ${BACKEND_PORT:-2283}
      BACKEND_SERVICE: ${BACKEND_SERVICE:-app-server}
      # Локальный CA / ручной TLS.
      CERT_NAME: ${CERT_NAME:-app}
    volumes:
      # Локальный CA / ручной TLS.
      - ./certs/live/${CERT_NAME:-app}/fullchain.pem:/certs/live/${CERT_NAME:-app}/fullchain.pem:ro
      - ./certs/live/${CERT_NAME:-app}/privkey.pem:/certs/live/${CERT_NAME:-app}/privkey.pem:ro
      # --- snip ---
```

А внутри Caddy они используются так:

```caddyfile
# caddy/Caddyfile
:443 {
	# Локальный CA / ручной TLS.
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	# --- snip ---
	reverse_proxy {$BACKEND_SERVICE}:{$BACKEND_PORT}
}
```

Запуск или пересоздание только Caddy:

```bash
docker compose up -d --no-deps --force-recreate caddy
```

Если Caddy уже запущен и менялся только `caddy/Caddyfile`, можно сделать перезагрузку без пересоздания контейнера:

```bash
docker compose exec -T caddy \
  caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

Проверить состояние:

```bash
docker compose ps caddy
```

## Шаг 8. Проверить HTTPS и редиректы

Для локального CA проверки ниже используют CA из `fullchain.pem`. Для Let’s Encrypt проверяйте публичное имя без `--cacert`: браузер и `curl` должны доверять цепочке из системного хранилища.

На этом этапе нужны переменные:

| Переменная | Где участвует |
| --- | --- |
| `APP_FQDN` | локальный CA: SAN; Let’s Encrypt: публичное DNS-имя |
| `APP_HOST` | локальный CA: короткое имя в SAN и редирект по короткому имени |
| `APP_IP` | локальный CA: IP в SAN и проверка HTTPS по IP |
| `LEGACY_HTTP_PORT` | проверка редиректа со старого порта |
| `CERT_NAME` | только локальный CA: путь к цепочке сертификатов |

Проверки опираются на эти части конфигов:

```ini
# certs/openssl/server.cnf
[alt_names]
DNS.1 = $ENV::APP_HOST
DNS.2 = $ENV::APP_FQDN
IP.1 = $ENV::APP_IP
```

```yaml
# docker-compose.override.yml
services:
  caddy:
    # --- snip ---
    ports:
      - "80:80"
      - "443:443"
      - "${LEGACY_HTTP_PORT:-2283}:2283"
```

```caddyfile
# caddy/Caddyfile
http://:80 {
	redir https://{host}{uri} permanent
}

http://:2283 {
	redir https://{host}{uri} permanent
}

:443 {
	# Локальный CA / ручной TLS.
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	# --- snip ---
}
```

Проверить HTTPS по имени:

```bash
curl --cacert <(awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n==2{print}' "certs/live/$CERT_NAME/fullchain.pem") \
  --resolve "$APP_FQDN:443:$APP_IP" \
  -I "https://$APP_FQDN/"
```

Ожидаемо:

```text
HTTP/2 200
```

Проверить HTTPS по IP:

```bash
curl --cacert <(awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n==2{print}' "certs/live/$CERT_NAME/fullchain.pem") \
  -I "https://$APP_IP/"
```

Ожидаемо:

```text
HTTP/2 200
```

Проверить редирект с `80` по имени:

```bash
curl -I --resolve "$APP_FQDN:80:$APP_IP" "http://$APP_FQDN/"
```

Ожидаемо:

```text
HTTP/1.1 301 Moved Permanently
Location: https://app.example.internal/
```

Проверить редирект с `80` по IP:

```bash
curl -I "http://$APP_IP/"
```

Ожидаемо:

```text
HTTP/1.1 301 Moved Permanently
Location: https://192.0.2.10/
```

Проверить редирект со старого порта по имени:

```bash
curl -I --resolve "$APP_FQDN:$LEGACY_HTTP_PORT:$APP_IP" \
  "http://$APP_FQDN:$LEGACY_HTTP_PORT/"
```

Ожидаемо:

```text
HTTP/1.1 301 Moved Permanently
Location: https://app.example.internal/
```

Проверить редирект со старого порта по IP:

```bash
curl -I "http://$APP_IP:$LEGACY_HTTP_PORT/"
```

Ожидаемо:

```text
HTTP/1.1 301 Moved Permanently
Location: https://192.0.2.10/
```

Главная мысль проверки: Caddy берёт исходный `Host` и убирает порт. Поэтому обращение по IP редиректит на IP:443, а обращение по имени редиректит на это же имя:443.

Посмотреть, какой сертификат реально отдаёт Caddy:

```bash
echo | openssl s_client -connect "$APP_IP:443" -servername "$APP_FQDN" -showcerts 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName -fingerprint -sha256
```

## Шаг 9. Подготовить репозиторий к публикации

На этом этапе переменные из `.env` уже не нужны. Здесь важно проверить, что в публикацию не попадёт лишнее.

В репозиторий должны попадать:

- `.env.example`;
- `.gitignore`;
- `README.md`;
- `docker-compose.override.yml`;
- `caddy/Caddyfile`;
- `certs/openssl/*.cnf`;
- `.gitkeep` файлы для пустых каталогов сертификатов.

В репозиторий не должны попадать:

- `.env`;
- рабочие сертификаты из `certs/live/**`;
- закрытые ключи;
- реальные сертификаты локального CA;
- серийные номера и временные файлы после выпуска сертификатов.

Проверить список файлов перед публикацией:

```bash
git init
git status --short
git check-ignore -v .env certs/live/app/fullchain.pem certs/live/app/privkey.pem
```

Если Git уже инициализирован, `git init` повторно выполнять не нужно. Если пока не хотите создавать репозиторий, просто проверьте, что `.env` и содержимое `certs/live/` закрыты правилами из `.gitignore`.

## Почему Caddy, а не Nginx

Nginx тоже рабочий вариант, особенно если он уже является общим входом на узле. Для этого шаблона Caddy выбран из прагматики:

- короткий `Caddyfile`;
- простой `reverse_proxy`;
- нормальная работа с WebSocket и заголовками прокси без лишней обвязки;
- ручной TLS через `tls cert key` для локального CA или автоматический HTTPS для публичного DNS-имени;
- меньше мест, где можно ошибиться в небольшой домашней установке.

Если в инфраструктуре уже есть Nginx и он централизованно обслуживает все приложения, логично оставить Nginx. Если нужен компактный прокси рядом с конкретным Compose-проектом, Caddy получается проще и быстрее в сопровождении.

## Полный пример конфигурации

Ниже полный рабочий пример для локального CA / ручного TLS. Для Let’s Encrypt через автоматический HTTPS Caddy убирают маунты `certs/live/...`, строку `tls ...` и используют публичное DNS-имя в адресе сайта.

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
      # Локальный CA / ручной TLS: имя каталога certs/live/<CERT_NAME>.
      # Для Let's Encrypt через автоматический HTTPS Caddy эта переменная не нужна.
      CERT_NAME: ${CERT_NAME:-app}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      # Локальный CA / ручной TLS: Caddy читает готовые fullchain.pem и privkey.pem.
      # Для Let's Encrypt эти маунты не нужны: Caddy хранит ACME-сертификаты в caddy-data.
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
	# Локальный CA / ручной TLS: редиректы описаны ниже явно.
	# Для Let's Encrypt обычно используют публичное DNS-имя в адресе сайта
	# и дают Caddy самому управлять HTTPS.
	auto_https disable_redirects
}

http://:80 {
	redir https://{host}{uri} permanent
}

http://:2283 {
	redir https://{host}{uri} permanent
}

:443 {
	# Локальный CA / ручной TLS: Caddy читает готовые сертификат и ключ.
	# Для Let's Encrypt эту строку убирают и используют адрес вида https://app.example.com.
	tls /certs/live/{$CERT_NAME}/fullchain.pem /certs/live/{$CERT_NAME}/privkey.pem
	encode zstd gzip

	reverse_proxy {$BACKEND_SERVICE}:{$BACKEND_PORT}
}
```

`certs/openssl/server.cnf`:

```ini
# Локальный CA / ручной TLS: CSR и расширения сертификата приложения.
# Для Let's Encrypt через автоматический HTTPS Caddy этот файл не нужен.

[req]
default_bits = 4096
default_md = sha256
distinguished_name = dn
prompt = no
req_extensions = v3_req

[dn]
CN = $ENV::APP_FQDN
O = $ENV::CERT_ORG
OU = $ENV::CERT_OU

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[v3_server_cert]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $ENV::APP_HOST
DNS.2 = $ENV::APP_FQDN
IP.1 = $ENV::APP_IP
```

`certs/openssl/root-ca.cnf`:

```ini
# Локальный CA / ручной TLS: самоподписанный корневой сертификат.
# Для Let's Encrypt через автоматический HTTPS Caddy этот файл не нужен.

[req]
default_bits = 4096
default_md = sha256
distinguished_name = dn
prompt = no
x509_extensions = v3_ca

[dn]
CN = $ENV::LOCAL_CA_CN
O = $ENV::CERT_ORG
OU = $ENV::LOCAL_CA_OU

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
```
