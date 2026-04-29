#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'docs test failed: %s\n' "$*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

require_file() {
  test -f "$1" || fail "missing file: $1"
}

require_grep() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file" || fail "missing expected pattern in $file: $pattern"
}

reject_grep() {
  local pattern="$1"
  shift
  if grep -RInE "$pattern" "$@" >/tmp/docs-test-grep.txt 2>/dev/null; then
    cat /tmp/docs-test-grep.txt >&2
    fail "forbidden pattern found"
  fi
}

require_file README.md
require_file CHANGELOG.md
require_file LICENSE
require_file .env.example
require_file .gitignore
require_file docker-compose.override.yml
require_file caddy/Caddyfile
require_file certs/live/.gitkeep
require_file certs/ca/.gitkeep
require_file .github/workflows/docs.yml
require_file .github/workflows/links.yml

test ! -e certs/openssl || fail "certs/openssl must not be published"

require_grep '^## Невыпущено$' CHANGELOG.md
require_grep '^MIT License$' LICENSE
require_grep 'actions/workflows/docs\.yml/badge\.svg' README.md
require_grep 'actions/workflows/links\.yml/badge\.svg' README.md
require_grep 'bash tests/docs\.sh' .github/workflows/docs.yml
require_grep 'lycheeverse/lychee-action@v2' .github/workflows/links.yml
require_grep 'External links' .github/workflows/links.yml
require_grep 'README\.md CHANGELOG\.md' .github/workflows/links.yml

for step in \
  'Шаг 1\. Заполнить переменные окружения' \
  'Шаг 2\. Получить сертификат' \
  'Шаг 3\. Найти службу приложения' \
  'Шаг 4\. Положить файлы рядом с Compose' \
  'Шаг 5\. Проверить Compose' \
  'Шаг 6\. Запустить или пересоздать Caddy' \
  'Шаг 7\. Проверить HTTPS и редиректы'
do
  require_grep "^## ${step}$" README.md
done

for anchor in \
  '#шаг-1-заполнить-переменные-окружения' \
  '#шаг-2-получить-сертификат' \
  '#шаг-3-найти-службу-приложения' \
  '#шаг-4-положить-файлы-рядом-с-compose' \
  '#шаг-5-проверить-compose' \
  '#шаг-6-запустить-или-пересоздать-caddy' \
  '#шаг-7-проверить-https-и-редиректы'
do
  grep -Fq "]($anchor)" README.md || fail "quick route anchor is missing: $anchor"
done

awk '
  BEGIN { in_code = 0; bad = 0 }
  /^```/ { in_code = !in_code }
  /# --- snip ---/ && !in_code {
    printf "%s:%d: # --- snip --- outside code block\n", FILENAME, NR
    bad = 1
  }
  END {
    if (in_code) {
      printf "%s: unclosed fenced code block\n", FILENAME
      bad = 1
    }
    exit bad
  }
' README.md || fail "README fenced code blocks are invalid"

for key in APP_FQDN APP_IP BACKEND_SERVICE BACKEND_PORT LEGACY_HTTP_PORT CERT_NAME; do
  grep -Eq "^${key}=" .env.example || fail "missing $key in .env.example"
  require_grep "\`${key}\`" README.md
done

reject_grep '^(APP_HOST|CERT_ORG|CERT_OU|LOCAL_CA_CN|LOCAL_CA_OU)=' .env.example
reject_grep 'certs/openssl|root-ca\.cnf|server\.cnf|Почему Caddy|Подготовить сертификаты|Проверить цепочку|Подготовить репозиторий' README.md .env.example docker-compose.override.yml caddy/Caddyfile .gitignore

require_grep '^  immich-server:$' docker-compose.override.yml
require_grep 'ports: !reset \[\]' docker-compose.override.yml
require_grep 'expose:' docker-compose.override.yml
require_grep '^  caddy:$' docker-compose.override.yml
require_grep '"80:80"' docker-compose.override.yml
require_grep '"443:443"' docker-compose.override.yml
require_grep '\$\{LEGACY_HTTP_PORT:-2283\}:2283' docker-compose.override.yml
require_grep 'BACKEND_SERVICE: \$\{BACKEND_SERVICE:-app-server\}' docker-compose.override.yml
require_grep '\./certs/live/\$\{CERT_NAME:-app\}/fullchain\.pem' docker-compose.override.yml
require_grep '\./certs/live/\$\{CERT_NAME:-app\}/privkey\.pem' docker-compose.override.yml

require_grep 'auto_https disable_redirects' caddy/Caddyfile
require_grep '^http://:80 ' caddy/Caddyfile
require_grep '^http://:2283 ' caddy/Caddyfile
require_grep '^:443 ' caddy/Caddyfile
require_grep 'tls /certs/live/\{\$CERT_NAME\}/fullchain\.pem /certs/live/\{\$CERT_NAME\}/privkey\.pem' caddy/Caddyfile
require_grep 'reverse_proxy \{\$BACKEND_SERVICE\}:\{\$BACKEND_PORT\}' caddy/Caddyfile

tracked_files="$(git ls-files)"
printf '%s\n' "$tracked_files" | grep -Fxq .env.example || fail ".env.example is not tracked"
printf '%s\n' "$tracked_files" | grep -Fxq CHANGELOG.md || fail "CHANGELOG.md is not tracked"
printf '%s\n' "$tracked_files" | grep -Fxq certs/live/.gitkeep || fail "certs/live/.gitkeep is not tracked"
printf '%s\n' "$tracked_files" | grep -Fxq certs/ca/.gitkeep || fail "certs/ca/.gitkeep is not tracked"
! printf '%s\n' "$tracked_files" | grep -Ev '^certs/(live|ca)/\.gitkeep$' | grep -Eq '^\.env$|^certs/live/.+|^certs/ca/.+\.(crt|key|pem|csr|srl)$' || fail "tracked secret/certificate file found"

git check-ignore -q .env || fail ".env is not ignored"
git check-ignore -q certs/live/app/fullchain.pem || fail "live fullchain is not ignored"
git check-ignore -q certs/live/app/privkey.pem || fail "live private key is not ignored"
git check-ignore -q certs/ca/example.crt || fail "CA certificate is not ignored"
git check-ignore -q certs/ca/private/example.key || fail "CA private key is not ignored"

tracked_text_files="$(git ls-files README.md CHANGELOG.md .env.example .gitignore docker-compose.override.yml caddy/Caddyfile)"
if printf '%s\n' "$tracked_text_files" | xargs grep -nE 'BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY|BEGIN CERTIFICATE|10\.4\.29\.69|BADABUM|immich-homelab-root-ca' >/tmp/docs-test-secrets.txt; then
  cat /tmp/docs-test-secrets.txt >&2
  fail "published files contain a real secret, certificate, or local-only value"
fi

if grep -Fq 'OWNER/REPO' README.md; then
  printf 'docs test note: replace OWNER/REPO in README badges before publishing the GitHub repository\n' >&2
fi

printf 'documentation tests passed\n'
