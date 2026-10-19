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

# apt 版の既定サービスは 80/443 を掴むので止める（設定の配布より前に止める）
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
# 証明書の保存先（XDG_DATA_HOME=/var/lib/caddy をユニットが使う）
install -d -m 755 /var/lib/caddy
if id -u caddy &>/dev/null; then chown caddy:caddy /var/lib/caddy; fi
install -d -m 755 /var/log/caddy
sed "s#@REPO_DIR@#${REPO_DIR}/duckdns#g" caddy-native.service > /etc/systemd/system/caddy-native.service
chmod 644 /etc/systemd/system/caddy-native.service
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
