#!/usr/bin/env bash
# EC2 上で 1 回だけ実行する: DuckDNS 更新フックと systemd ユニットを配置する
#   sudo ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

[[ $EUID -eq 0 ]] || { echo "sudo で実行してください: sudo $0" >&2; exit 1; }

echo "=== DuckDNS ==="
read -rp "ドメイン (例: mypi.duckdns.org): " DOMAIN
[[ "$DOMAIN" == *".duckdns.org" ]] || { echo "duckdns.org のドメインを指定してください" >&2; exit 1; }
read -rp "DuckDNS のトークン: " DTOKEN

install -d -m 700 /etc/pi-web
umask 077
cat > /etc/pi-web/duckdns.env <<EOF
DUCKDNS_DOMAIN=${DOMAIN}
DUCKDNS_TOKEN=${DTOKEN}
EOF
chmod 600 /etc/pi-web/duckdns.env

install -m 755 update-duckdns.sh /usr/local/bin/pi-web-duckdns-update
install -m 644 pi-web-duckdns.service /etc/systemd/system/
install -m 644 pi-web-duckdns.timer /etc/systemd/system/
install -m 644 pi-web.service /etc/systemd/system/
[[ -f caddy.service ]] && install -m 644 caddy.service /etc/systemd/system/ || true

systemctl daemon-reload
systemctl enable --now pi-web-duckdns.timer

echo
echo "初回の更新を実行します..."
/usr/local/bin/pi-web-duckdns-update || echo "（失敗。トークンと SG を確認）"
echo
systemctl list-timers pi-web-duckdns.timer --no-pager || true
cat <<MSG

配置しました:
  /etc/pi-web/duckdns.env               (600, DuckDNS のトークン)
  /usr/local/bin/pi-web-duckdns-update
  /etc/systemd/system/pi-web-duckdns.{service,timer}
  /etc/systemd/system/pi-web.service
  /etc/systemd/system/caddy.service     （あれば）

次:
  sudo systemctl enable --now pi-web
  sudo systemctl enable --now caddy     （docker compose を systemd 管理にする場合）
  systemctl status pi-web --no-pager
MSG
