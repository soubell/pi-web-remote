#!/usr/bin/env bash
# .env.caddy を生成する（初回のみ）
#   DuckDNS のドメイン / トークン と、Caddy の Basic 認証（bcrypt ハッシュ）を書き出す
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "エラー: $*" >&2; exit 1; }

[[ -f .env.caddy ]] && die ".env.caddy が既にあります。作り直すなら先に削除してください"
command -v docker >/dev/null || die "docker が必要です"

echo "=== DuckDNS ==="
read -rp "ドメイン (例: mypi.duckdns.org): " DOMAIN
[[ "$DOMAIN" == *".duckdns.org" ]] || die "duckdns.org のドメインを指定してください"
read -rp "DuckDNS のトークン: " DTOKEN
read -rp "ACME 登録メール (空でも可): " EMAIL

echo
echo "=== Basic 認証（Pi Web のパスワードとは別の値にする） ==="
read -rp "ユーザー名 [pi]: " BUSER; BUSER="${BUSER:-pi}"
read -rsp "パスワード: " BPASS; echo
read -rsp "パスワード (確認): " BPASS2; echo
[[ "$BPASS" == "$BPASS2" ]] || die "パスワードが一致しません"
[[ ${#BPASS} -ge 12 ]] || die "短すぎます（12文字以上を推奨）"

echo "bcrypt ハッシュを生成中..."
# パスワードは argv に載せず stdin から渡す（ps で見えないように）
HASH="$(printf '%s' "$BPASS" | docker run -i --rm caddy:2.11 caddy hash-password | tr -d '\r')"
[[ "$HASH" == \$2* ]] || die "ハッシュ生成に失敗しました: $HASH"

umask 077
cat > .env.caddy <<EOF
DUCKDNS_DOMAIN=${DOMAIN}
DUCKDNS_API_TOKEN=${DTOKEN}
ACME_EMAIL=${EMAIL}
BASIC_AUTH_USER=${BUSER}
BASIC_AUTH_HASH=${HASH}
PI_WEB_UPSTREAM=host.docker.internal:30141
EOF
chmod 600 .env.caddy

cat <<MSG

生成しました: .env.caddy (chmod 600)
  → .gitignore 済み。絶対にコミットしないこと。
  → BASIC_AUTH_HASH には \$ が含まれるが、env_file 経由なので docker compose の
    変数展開はかからない。environment: に移す場合は \$ を \$\$ にエスケープする。

次の手順:
  1) Pi Web をホスト側で起動（別ターミナル / systemd）
     PI_WEB_PASSWORD='(32文字ランダム)' \\
     PI_WEB_ALLOWED_HOSTS='${DOMAIN}' \\
     PI_WEB_IDLE_TIMEOUT_MS=0 \\
       npx @agegr/pi-web@latest -H 127.0.0.1 -p 30141 --no-open

  2) docker compose up -d --build
  3) docker compose logs -f caddy     # 証明書取得のログ（初回 30〜90 秒）
  4) https://${DOMAIN} → Basic 認証 → Pi Web のパスワード画面

MSG
