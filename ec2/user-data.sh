#!/bin/bash
# EC2 (Ubuntu 24.04 LTS) の初回起動時に流す cloud-init テンプレート
#   - Node.js 22 と Pi Web 専用ユーザーを用意する（Docker は入れない）
#   - Pi Web 自体の起動はしない（パスワード等の秘密は user-data に書かない）
# 使い方: EC2 起動時の「高度な詳細 > ユーザーデータ」にこのファイルを貼る
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg git unzip

# --- t3.micro (1GB) でも npm install が通るように swap を 2GB 用意 ----------------
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Docker は入れない ---------------------------------------------------------
# 標準構成は「ネイティブ Caddy（apt）+ DuckDNS」で Docker を使わない。
# 約 3GB の節約になり、8GB の EBS でも余裕ができる。
# Docker 版 Caddy（../duckdns）を使う場合だけ、後から自分で導入する:
#   curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker ubuntu

# --- Node.js 22 (Pi Web は 22.19 以上が必要) -----------------------------------
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
node --version

# --- Pi Web 専用ユーザー（エージェントは bash を実行できるので分離する） --------
id -u piweb &>/dev/null || useradd -m -s /bin/bash piweb
install -d -o piweb -g piweb /home/piweb/.config/pi-web

# --- IMDS (169.254.169.254) への到達を piweb から塞ぐ ---------------------------
#   エージェント経由でインスタンスメタデータ（IAM 資格情報）を読まれないようにする
iptables -C OUTPUT -m owner --uid-owner piweb -d 169.254.169.254 -j REJECT 2>/dev/null || \
  iptables -A OUTPUT -m owner --uid-owner piweb -d 169.254.169.254 -j REJECT
apt-get install -y iptables-persistent || true
netfilter-persistent save || true

echo "bootstrap done. 次は systemd ユニットと .env.caddy を配置する（README 参照）"
