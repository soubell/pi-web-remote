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

echo "[1/5] Caddy を公式リポジトリから導入..."
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

# apt 版の既定サービス（caddy.service）を止めるのは「設定の検証が通った後」。
# ここで止めてしまうと、install.sh の caddy validate が失敗したときに
# 何も動いていない状態で終わってしまう（→ [4/5] で停止する）。

echo "[2/5] caddy-native.service を配置..."
id -u caddy &>/dev/null || die "ユーザー caddy がありません（caddy パッケージの導入に失敗？）"
command -v caddy >/dev/null 2>&1 || die "caddy コマンドがありません（導入に失敗）"

install -d -m 755 /etc/pi-web /var/lib/caddy /var/log/caddy
chown caddy:caddy /var/lib/caddy /var/log/caddy
# unit を先に置く。install.sh は「unit が無ければ中止」する設計なので順序が重要
install -m 644 caddy-native.service /etc/systemd/system/caddy-native.service
ok "/etc/systemd/system/caddy-native.service"

echo "[3/5] 設定の配布（install.sh: 検証してから一括反映）..."
# 設定の中身は install.sh が一元管理する（ここで直接書くと検証前に本番を触ることになる）
( cd "$REPO_DIR/ec2" && ./install.sh )

echo "[4/5] 既存の Caddy を止めて、ネイティブ版を起動..."

# 検証と反映が終わったので、ここで初めて既存サービスを止める（失敗しても被害が出ない）
LEGACY_STOPPED=0
if systemctl list-unit-files caddy.service >/dev/null 2>&1 \
   && systemctl is-active --quiet caddy.service 2>/dev/null; then
  systemctl disable --now caddy.service && LEGACY_STOPPED=1
  ok "既存の caddy.service を停止・無効化"
fi

# 443 がまだ埋まっているなら Docker 版などが掴んでいる。無理に起動しない
if command -v ss >/dev/null && ss -ltn 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}'; then
  [[ "$LEGACY_STOPPED" -eq 1 ]] && sleep 2
  if ss -ltn 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}'; then
    echo "エラー: 443 が他のプロセスに使われています。設定は反映済みですが起動していません。" >&2
    echo "       Docker 版 Caddy が動いている場合: cd ${REPO_DIR}/duckdns && docker compose down" >&2
    echo "       占有元の確認: sudo ss -ltnp | grep :443" >&2
    exit 1
  fi
fi

systemctl daemon-reload
if ! systemctl enable --now caddy-native.service; then
  echo "エラー: caddy-native.service を起動できませんでした。journalctl -u caddy-native を確認してください" >&2
  exit 1
fi
# Type=simple は起動直後に落ちても成功を返すので、active になるまで待つ
for i in 1 2 3 4 5 6 7 8 9 10; do
  systemctl is-active --quiet caddy-native.service && break
  sleep 1
done
if ! systemctl is-active --quiet caddy-native.service; then
  systemctl --no-pager --lines=15 status caddy-native.service || true
  die "caddy-native.service が active になりませんでした（上記ログを確認）"
fi
ok "caddy-native.service 起動（active を確認）"

echo "[5/5] 確認先の案内..."
DOMAIN="$(grep -E '^DUCKDNS_DOMAIN=' "$REPO_DIR/duckdns/.env.caddy" | cut -d= -f2-)"
cat <<MSG

完了。次:
  sudo systemctl enable --now pi-web
  sudo ./check.sh

確認:
  journalctl -u caddy-native -f            # 証明書取得のログ
  curl -sI https://${DOMAIN} | head -1     # -> HTTP/2 401

設定を変えたとき（ec2/.env を編集後）:
  sudo ./install.sh        # 検証 → 反映 → 再起動 → 事後確認まで面倒を見る
  # （再起動は install.sh が行うので、手で restart する必要はない）

Docker 版に切り替える場合（非標準）:
  sudo systemctl disable --now caddy-native
  cd ${REPO_DIR}/duckdns && docker compose up -d --build
MSG
