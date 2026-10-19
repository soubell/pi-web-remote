#!/usr/bin/env bash
# Docker を使わず、素の Caddy を apt で入れて動かす（EC2 / VPS 向け）
#
#   sudo ./install-caddy-native.sh
#
# これ 1 本で完結する:
#   1. Caddy を導入（先に入れることで install.sh の bcrypt 生成が caddy を使える）
#   2. .env.caddy が無ければ install.sh を実行（設定の配布 + systemd 配置）
#   3. caddy-native.service を配置して起動（TLS-ALPN-01 で証明書取得）
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "エラー: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }

[[ $EUID -eq 0 ]] || die "sudo で実行してください: sudo $0"
REPO_DIR="$(cd .. && pwd)"
[[ -f ./.env ]] || die "ec2/.env がありません。cp .env.example .env して値を入れてください"

echo "[1/4] Caddy を公式リポジトリから導入..."
if ! command -v caddy >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
fi
ok "$(caddy version | head -1)"

# apt 版の既定サービス / Docker 版が 443 を掴むので止める
if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
  systemctl disable --now caddy.service 2>/dev/null || true
fi

echo "[2/4] 設定の配布（install.sh）..."
if [[ ! -f "$REPO_DIR/duckdns/.env.caddy" ]]; then
  ( cd "$REPO_DIR/ec2" && ./install.sh )
else
  ok "../duckdns/.env.caddy は既にあり（install.sh 実行済み）"
fi
[[ -f "$REPO_DIR/duckdns/.env.caddy" ]] || die "install.sh が .env.caddy を作れませんでした"

echo "[3/4] caddy-native.service を配置..."
id -u caddy &>/dev/null || die "ユーザー caddy がありません（caddy パッケージの導入に失敗？）"

# 設定は /etc/pi-web に集約する（caddy ユーザーから読めるようにするため）
install -d -m 755 /etc/pi-web /var/lib/caddy /var/log/caddy
chown caddy:caddy /var/lib/caddy /var/log/caddy
# .env.caddy は 600 (clone したユーザー所有) なので、caddy が読める 0640 root:caddy の写しを作る
install -m 640 -o root -g caddy "$REPO_DIR/duckdns/.env.caddy" /etc/pi-web/caddy.env
install -m 644 "$REPO_DIR/duckdns/Caddyfile.native" /etc/pi-web/Caddyfile
ok "/etc/pi-web/caddy.env（root:caddy 0640）"
ok "/etc/pi-web/Caddyfile"

# 起動前に設定を検証（壊れた Caddyfile で再起動ループに入るのを防ぐ）
#   ※ `source` すると BASIC_AUTH_HASH の `$` が展開されて壊れるのでデータとして読む
(
  set -e
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"; v="${line#*=}"
    printf -v "$k" '%s' "$v"; export "${k?}"
  done < /etc/pi-web/caddy.env
  caddy validate --config /etc/pi-web/Caddyfile >/dev/null
) || die "Caddyfile の検証に失敗しました（caddy validate を直接実行して確認）"
ok "caddy validate"

install -m 644 caddy-native.service /etc/systemd/system/caddy-native.service
ok "/etc/systemd/system/caddy-native.service"

echo "[4/4] 起動..."
systemctl daemon-reload
systemctl enable --now caddy-native.service
sleep 2
systemctl --no-pager --lines=5 status caddy-native.service || true

DOMAIN="$(grep -E '^DUCKDNS_DOMAIN=' "$REPO_DIR/duckdns/.env.caddy" | cut -d= -f2-)"
cat <<MSG

完了。次:
  sudo systemctl enable --now pi-web
  sudo ./check.sh

確認:
  journalctl -u caddy-native -f            # 証明書取得のログ
  curl -sI https://${DOMAIN} | head -1     # -> HTTP/2 401

設定を変えたとき（ec2/.env を編集後）:
  sudo ./install.sh && sudo systemctl restart caddy-native pi-web

Docker 版に戻す場合:
  sudo systemctl disable --now caddy-native
  cd ${REPO_DIR}/duckdns && docker compose up -d --build
MSG
