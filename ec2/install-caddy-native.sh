#!/usr/bin/env bash
# Docker を使わず、素の Caddy を apt で入れて動かす（EC2 / VPS 向け）
#   前提: `sudo ./install.sh` 実行済み（.env.caddy が作られていること）
#   証明書は TLS-ALPN-01 で取得するので、443 が外から到達できる必要がある
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "エラー: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }

[[ $EUID -eq 0 ]] || die "sudo で実行してください: sudo $0"
REPO_DIR="$(cd .. && pwd)"
[[ -f "$REPO_DIR/duckdns/.env.caddy" ]] || die "duckdns/.env.caddy がありません。先に sudo ./install.sh を実行してください"

echo "[1/3] Caddy を公式リポジトリから導入..."
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

echo "[2/3] Caddyfile とユニットを配置..."
install -d -m 755 /var/log/caddy
install -d -o caddy -g caddy -m 755 /var/lib/caddy 2>/dev/null || true
# ネイティブ版は Caddyfile.native を使う（Docker 版の Caddyfile は触らない）
sed "s#@REPO_DIR@#${REPO_DIR}/duckdns#g" caddy-native.service > /etc/systemd/system/caddy-native.service
chmod 644 /etc/systemd/system/caddy-native.service
ok "/etc/systemd/system/caddy-native.service"

# apt 版の既定サービスは 80/443 を掴むので止める
if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
  systemctl disable --now caddy.service 2>/dev/null || true
fi
# Docker 版が動いていたら止める（443 の取り合いを避ける）
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-web-caddy; then
  echo "  Docker 版 Caddy を停止..."
  (cd "$REPO_DIR/duckdns" && docker compose down) || true
  systemctl disable --now caddy.service 2>/dev/null || true
fi

echo "[3/3] 起動..."
systemctl daemon-reload
systemctl enable --now caddy-native.service
sleep 2
systemctl --no-pager --lines=5 status caddy-native.service || true

DOMAIN="$(grep -E '^DUCKDNS_DOMAIN=' "$REPO_DIR/duckdns/.env.caddy" | cut -d= -f2-)"
cat <<MSG

完了。確認:
  journalctl -u caddy-native -f      # 証明書取得のログ
  curl -sI https://${DOMAIN} | head -1   # -> HTTP/2 401

Docker 版に戻す場合:
  sudo systemctl disable --now caddy-native
  cd ${REPO_DIR}/duckdns && docker compose up -d --build
MSG
