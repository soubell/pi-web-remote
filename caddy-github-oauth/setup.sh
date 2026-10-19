#!/usr/bin/env bash
# .env.caddy と .env.oauth を生成する（初回のみ）
#   秘密情報はすべてここで入力し、各ファイルは chmod 600 で保存する
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "エラー: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 が見つかりません"; }

[[ -f .env.caddy || -f .env.oauth ]] && die ".env.* が既にあります。作り直すなら先に削除してください"
need docker

echo "=== DuckDNS ==="
read -rp "ドメイン (例: mypi.duckdns.org): " DOMAIN
[[ "$DOMAIN" == *".duckdns.org" ]] || die "duckdns.org のドメインを指定してください"
read -rp "DuckDNS のトークン: " DTOKEN
read -rp "ACME 登録メール (空でも可): " EMAIL

echo
echo "=== GitHub OAuth App ==="
echo "https://github.com/settings/developers → New OAuth App"
echo "  Homepage URL           : https://${DOMAIN}"
echo "  Authorization callback : https://${DOMAIN}/oauth2/callback"
read -rp "Client ID: " CID
read -rsp "Client Secret: " CSECRET; echo
read -rp "許可する GitHub ユーザー名 (自分の login): " GHUSER
[[ -n "$GHUSER" ]] || die "GitHub ユーザー名は必須です（これが無いと誰でもログインできます）"

# cookie secret: 32 バイトの base64（oauth2-proxy の要件）
if command -v openssl >/dev/null; then
  COOKIE_SECRET="$(openssl rand -base64 32 | tr -- '+/' '-_' | tr -d '=')"
else
  COOKIE_SECRET="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))')"
fi
[[ ${#COOKIE_SECRET} -ge 32 ]] || die "cookie secret の生成に失敗しました"

umask 077
cat > .env.caddy <<EOF
DUCKDNS_DOMAIN=${DOMAIN}
DUCKDNS_API_TOKEN=${DTOKEN}
ACME_EMAIL=${EMAIL}
PI_WEB_UPSTREAM=host.docker.internal:30141
EOF

cat > .env.oauth <<EOF
OAUTH2_PROXY_PROVIDER=github
OAUTH2_PROXY_CLIENT_ID=${CID}
OAUTH2_PROXY_CLIENT_SECRET=${CSECRET}
OAUTH2_PROXY_COOKIE_SECRET=${COOKIE_SECRET}
OAUTH2_PROXY_COOKIE_SECURE=true
OAUTH2_PROXY_COOKIE_SAMESITE=lax
OAUTH2_PROXY_COOKIE_EXPIRE=24h
OAUTH2_PROXY_REVERSE_PROXY=true
OAUTH2_PROXY_REDIRECT_URL=https://${DOMAIN}/oauth2/callback
OAUTH2_PROXY_UPSTREAMS=static://202
OAUTH2_PROXY_SET_XAUTHREQUEST=true
OAUTH2_PROXY_EMAIL_DOMAINS=*
OAUTH2_PROXY_GITHUB_USER=${GHUSER}
EOF
chmod 600 .env.caddy .env.oauth

cat <<MSG

生成しました: .env.caddy / .env.oauth (chmod 600)
  → これらは .gitignore 済み。絶対にコミットしないこと。

次の手順:
  1) Pi Web をホスト側で起動（別ターミナル / systemd）
     PI_WEB_PASSWORD='(長いランダム)' \\
     PI_WEB_ALLOWED_HOSTS='${DOMAIN}' \\
     PI_WEB_IDLE_TIMEOUT_MS=0 \\
       npx @agegr/pi-web@latest -H 127.0.0.1 -p 30141 --no-open

  2) docker compose up -d --build
  3) docker compose logs -f caddy     # 証明書取得のログ
  4) https://${DOMAIN} → GitHub ログイン → Pi Web のパスワード画面

MSG
