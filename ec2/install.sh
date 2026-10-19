#!/usr/bin/env bash
# ec2/.env の 1 ファイルから、各サービスの環境変数を配布し、systemd ユニットを配置する
#
#   cd ec2
#   cp .env.example .env && nano .env     # 値を埋める
#   sudo ./install.sh
#
# 配布先:
#   ../duckdns/.env.caddy             (Caddy / docker compose の env_file)
#   /etc/pi-web/duckdns.env           (root が実行する DuckDNS 更新スクリプト)
#   /home/piweb/.config/pi-web/env    (Pi Web / systemd の EnvironmentFile)
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

die() { echo "エラー: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }

# --- 0) 前提 ----------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
  [[ $EUID -eq 0 ]] || die "sudo で実行してください: sudo $0"
fi
ENV_FILE=".env"
[[ -f "$ENV_FILE" ]] || die "$(pwd)/.env がありません。cp .env.example .env して値を入れてください"

# shellcheck disable=SC1090
set -a; . "./$ENV_FILE"; set +a

: "${DUCKDNS_DOMAIN:?DUCKDNS_DOMAIN が空です}"
: "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN が空です}"
: "${BASIC_AUTH_PASSWORD:?BASIC_AUTH_PASSWORD が空です}"
: "${PI_WEB_PASSWORD:?PI_WEB_PASSWORD が空です}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-pi}"
ACME_EMAIL="${ACME_EMAIL:-}"
PI_WEB_IDLE_TIMEOUT_MS="${PI_WEB_IDLE_TIMEOUT_MS:-0}"
SUB="${DUCKDNS_DOMAIN%.duckdns.org}"

[[ "$DUCKDNS_DOMAIN" == *".duckdns.org" ]] || die "DUCKDNS_DOMAIN は *.duckdns.org にしてください"
[[ ${#BASIC_AUTH_PASSWORD} -ge 12 ]] || die "BASIC_AUTH_PASSWORD は 12 文字以上にしてください"
[[ ${#PI_WEB_PASSWORD}   -ge 16 ]] || die "PI_WEB_PASSWORD は 16 文字以上にしてください"
[[ "$BASIC_AUTH_PASSWORD" != "$PI_WEB_PASSWORD" ]] || die "2 つのパスワードは別の値にしてください"
id -u piweb &>/dev/null || die "ユーザー piweb がありません（user-data.sh か手動で作成してください）"

# --- 1) bcrypt ハッシュを生成（Docker の caddy を使う） ----------------------
command -v docker >/dev/null || die "docker が必要です（Caddy のハッシュ生成に使用）"
echo "[1/4] Basic 認証のハッシュを生成..."
BASIC_AUTH_HASH="$(printf '%s' "$BASIC_AUTH_PASSWORD" | docker run -i --rm caddy:2.11 caddy hash-password | tr -d '\r')"
[[ "$BASIC_AUTH_HASH" == \$2* ]] || die "ハッシュ生成に失敗: $BASIC_AUTH_HASH"
ok "bcrypt 生成"

if [[ $DRY_RUN -eq 1 ]]; then
  cat <<EOF
[dry-run] 以下を書き込む予定（パスワードは伏字）:
  ../duckdns/.env.caddy
    DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
    DUCKDNS_API_TOKEN=***
    ACME_EMAIL=${ACME_EMAIL}
    BASIC_AUTH_USER=${BASIC_AUTH_USER}
    BASIC_AUTH_HASH=${BASIC_AUTH_HASH:0:7}***
    PI_WEB_UPSTREAM=host.docker.internal:30141
  /etc/pi-web/duckdns.env
    DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
    DUCKDNS_TOKEN=***
  /home/piweb/.config/pi-web/env
    PI_WEB_PASSWORD=***
    PI_WEB_ALLOWED_HOSTS=${DUCKDNS_DOMAIN}
    PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS}
    PI_WEB_NO_OPEN=1
EOF
  exit 0
fi

# --- 2) 配布 ----------------------------------------------------------------
echo "[2/4] 環境変数を配布..."

# (a) Caddy
umask 077
cat > ../duckdns/.env.caddy <<EOF
DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
DUCKDNS_API_TOKEN=${DUCKDNS_TOKEN}
ACME_EMAIL=${ACME_EMAIL}
BASIC_AUTH_USER=${BASIC_AUTH_USER}
BASIC_AUTH_HASH=${BASIC_AUTH_HASH}
PI_WEB_UPSTREAM=host.docker.internal:30141
EOF
chmod 600 ../duckdns/.env.caddy
ok "../duckdns/.env.caddy"

# (b) DuckDNS 更新スクリプト（root 実行）
install -d -m 700 /etc/pi-web
cat > /etc/pi-web/duckdns.env <<EOF
DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
EOF
chmod 600 /etc/pi-web/duckdns.env
ok "/etc/pi-web/duckdns.env"

# (c) Pi Web（piweb ユーザー）
install -d -o piweb -g piweb -m 700 /home/piweb/.config/pi-web
cat > /home/piweb/.config/pi-web/env <<EOF
PI_WEB_PASSWORD=${PI_WEB_PASSWORD}
PI_WEB_ALLOWED_HOSTS=${DUCKDNS_DOMAIN}
PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS}
PI_WEB_NO_OPEN=1
EOF
chown piweb:piweb /home/piweb/.config/pi-web/env
chmod 600 /home/piweb/.config/pi-web/env
ok "/home/piweb/.config/pi-web/env"

# ec2/.env 自体も 600 にしておく（平文パスワードが入っているため）
chmod 600 ./.env

# --- 3) systemd ユニット ----------------------------------------------------
echo "[3/4] systemd ユニットを配置..."
install -m 755 update-duckdns.sh /usr/local/bin/pi-web-duckdns-update
for u in pi-web-duckdns.service pi-web-duckdns.timer pi-web.service caddy.service; do
  [[ -f "$u" ]] || continue
  install -m 644 "$u" /etc/systemd/system/"$u"
  ok "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now pi-web-duckdns.timer
ok "pi-web-duckdns.timer 有効化"

# --- 4) 初回の DuckDNS 更新 --------------------------------------------------
echo "[4/4] DuckDNS を現在の IP に更新..."
if /usr/local/bin/pi-web-duckdns-update; then :; else
  echo "  ! 更新に失敗しました。トークンとアウトバウンド 443 を確認してください" >&2
fi

cat <<MSG

完了。配布内容は ec2/.env の 1 ファイルが正である。

次:
  sudo systemctl enable --now pi-web caddy
  systemctl status pi-web --no-pager
  docker compose -f ../duckdns/docker-compose.yml logs -f caddy

確認:
  curl -sI https://${DUCKDNS_DOMAIN} | head -1     # -> HTTP/2 401

設定を変えたいとき:
  nano $(pwd)/.env   →   sudo ./install.sh   をもう一度実行（上書き配布）
MSG
