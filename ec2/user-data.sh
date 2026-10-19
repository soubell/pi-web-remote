#!/bin/bash
# EC2 (Ubuntu 24.04 LTS) の初回起動時に流す cloud-init テンプレート
#   - Docker / Node.js 22 / Pi Web 専用ユーザーを用意する
#   - Pi Web 自体の起動はしない（パスワード等の秘密は user-data に書かない）
# 使い方: EC2 起動時の「高度な詳細 > ユーザーデータ」にこのファイルを貼る
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg git unzip

# --- t3.micro (1GB) でも Caddy のビルドが通るように swap を 2GB 用意 -------------
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Docker + compose plugin ---------------------------------------------------
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu || true

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
