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

# --- 切り替えを 1 つのトランザクションとして扱う -------------------------------
#   既存 Caddy の停止 → 新 unit の起動 は不可分に行う。途中で失敗したら
#   「設定」と「既存サービスの稼働状態」の両方を元に戻す。
SWITCH_STARTED=0
SWITCH_DONE=0
SNAP=""
LEGACY_WAS_ACTIVE=0
LEGACY_WAS_ENABLED=0

restore_switch() {
  local why="$1"
  SWITCH_DONE=1          # 二重に復元しない（明示的な復元後に EXIT が走るため）
  echo "  ! 切り替えに失敗（${why}）。元に戻します" >&2

  # 新 unit を止める（動いていれば）
  systemctl stop caddy-native.service >/dev/null 2>&1 || true

  # 設定を戻す
  if [[ -n "$SNAP" && -d "$SNAP" ]]; then
    [[ -d "$SNAP/etc-pi-web" ]] && { rm -rf /etc/pi-web; cp -a "$SNAP/etc-pi-web" /etc/pi-web; }
    [[ -f "$SNAP/caddy-native.service" ]] && cp -a "$SNAP/caddy-native.service" /etc/systemd/system/caddy-native.service
    [[ -f "$SNAP/piweb-env" ]] && cp -a "$SNAP/piweb-env" /home/piweb/.config/pi-web/env
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo "  ! 設定を切り替え前の状態に戻しました" >&2
  fi

  # 既存の caddy.service を元通りに
  if [[ "$LEGACY_WAS_ACTIVE" -eq 1 ]]; then
    if [[ "$LEGACY_WAS_ENABLED" -eq 1 ]]; then
      systemctl enable --now caddy.service >/dev/null 2>&1 || systemctl start caddy.service >/dev/null 2>&1 || true
    else
      systemctl start caddy.service >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet caddy.service 2>/dev/null; then
      echo "  ✓ 既存の caddy.service を再開しました" >&2
    else
      echo "  ! 既存の caddy.service を再開できませんでした。手動で確認してください" >&2
    fi
  fi
  [[ -n "$SNAP" ]] && rm -rf "$SNAP"
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [[ "$SWITCH_STARTED" -eq 1 && "$SWITCH_DONE" -eq 0 ]]; then
    restore_switch "予期しない失敗（終了コード ${rc}）"
    rc=1
  fi
  [[ -n "$SNAP" && -d "$SNAP" ]] && rm -rf "$SNAP"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
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

# --- 切り替え前の状態を退避 ------------------------------------------------
#   install.sh は成功時に自分のバックアップを破棄するので、その外側で
#   「切り替え前の状態」をここで確保しておく（起動失敗時に戻すため）。
SNAP="$(mktemp -d /tmp/caddy-switch.XXXXXX)"
[[ -d /etc/pi-web ]] && cp -a /etc/pi-web "$SNAP/etc-pi-web"
[[ -f /etc/systemd/system/caddy-native.service ]] && \
  cp -a /etc/systemd/system/caddy-native.service "$SNAP/caddy-native.service"
[[ -f /home/piweb/.config/pi-web/env ]] && \
  cp -a /home/piweb/.config/pi-web/env "$SNAP/piweb-env"
if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
  systemctl is-active  --quiet caddy.service 2>/dev/null && LEGACY_WAS_ACTIVE=1
  systemctl is-enabled --quiet caddy.service 2>/dev/null && LEGACY_WAS_ENABLED=1
fi
SWITCH_STARTED=1

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

systemctl daemon-reload || { restore_switch "daemon-reload に失敗"; die "daemon-reload に失敗しました"; }

# 既存サービスを止める（ここから先は失敗時に元へ戻す）
if [[ "$LEGACY_WAS_ACTIVE" -eq 1 ]]; then
  if systemctl disable --now caddy.service; then
    ok "既存の caddy.service を停止・無効化"
    sleep 1
  else
    restore_switch "既存の caddy.service を停止できない"
    die "既存の Caddy を停止できませんでした。何も変更していません"
  fi
fi

# 443 がまだ埋まっているなら別プロセス（Docker 版など）が掴んでいる
if command -v ss >/dev/null && ss -ltn 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}'; then
  restore_switch "443 が他のプロセスに使われている"
  echo "エラー: 443 が使用中です。切り替えを中止し、元の状態に戻しました。" >&2
  echo "       Docker 版 Caddy が動いている場合: cd ${REPO_DIR}/duckdns && docker compose down" >&2
  echo "       占有元の確認: sudo ss -ltnp | grep :443" >&2
  exit 1
fi

if ! systemctl enable --now caddy-native.service; then
  systemctl --no-pager --lines=15 status caddy-native.service || true
  restore_switch "caddy-native.service を起動できない"
  die "caddy-native.service を起動できませんでした（元の状態に戻しました）。journalctl -u caddy-native を確認してください"
fi

# Type=simple は起動直後に落ちても成功を返すので、active になるまで待つ
ACTIVE=0
for i in $(seq 1 15); do
  systemctl is-active --quiet caddy-native.service && { ACTIVE=1; break; }
  sleep 1
done
if [[ "$ACTIVE" -eq 0 ]]; then
  systemctl --no-pager --lines=15 status caddy-native.service || true
  restore_switch "caddy-native.service が active にならない"
  die "caddy-native.service が 15 秒以内に active になりませんでした（元の状態に戻しました）"
fi

# 443 を実際に掴めているか（証明書取得前でも LISTEN はする）
if command -v ss >/dev/null && ! ss -ltn 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}'; then
  restore_switch "443 を LISTEN していない"
  die "caddy-native は起動しましたが 443 を LISTEN していません（元の状態に戻しました）"
fi

SWITCH_DONE=1
ok "caddy-native.service 起動（active / 443 LISTEN を確認）"

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
