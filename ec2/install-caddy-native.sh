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

# ユニットが active になるまで待つ（Type=simple は直後に落ちても start が成功する）
wait_active() {          # <unit> <待ち秒>
  local unit="$1" want="${2:-15}" i
  for (( i=0; i<want; i++ )); do
    systemctl is-active --quiet "$unit" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

restore_switch() {
  local why="$1" t key bad=0
  SWITCH_DONE=1          # 二重に復元しない（明示的な復元後に EXIT が走るため）
  echo "  ! 切り替えに失敗（${why}）。元に戻します" >&2

  # 1) 新 unit を止める（動いていれば）
  systemctl stop caddy-native.service >/dev/null 2>&1 || true

  # 2) 設定を退避から戻す。退避が無い＝新規作成されたファイルなので削除する
  if [[ -n "$SNAP" && -d "$SNAP" ]]; then
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      key="$(printf '%s' "$t" | tr '/' '_')"
      if [[ -f "$SNAP/existed/$key" ]]; then
        if cp -a "$SNAP/keep/$key" "$t" 2>/dev/null; then
          :
        else
          echo "  ! 復元に失敗: $t" >&2; bad=1
        fi
      else
        rm -f "$t" 2>/dev/null || { echo "  ! 削除に失敗: $t" >&2; bad=1; }
      fi
    done < "$SNAP/targets"

    # 切り替え前に無かったディレクトリは、空なら片付ける
    if [[ -f "$SNAP/newdirs" ]]; then
      while IFS= read -r t; do
        [[ -n "$t" ]] && rmdir "$t" 2>/dev/null
      done < "$SNAP/newdirs"
    fi

    systemctl daemon-reload >/dev/null 2>&1 || { echo "  ! daemon-reload に失敗" >&2; bad=1; }
    if [[ "$bad" -eq 0 ]]; then
      echo "  ! 設定を切り替え前の状態に戻しました" >&2
    else
      echo "  ! 設定の復元が一部失敗しています（手動確認が必要）" >&2
    fi

    # 2-b) サービスの稼働状態を元に戻す
    #      「旧ファイル＋新設定を読んだプロセス」という食い違いを残さないため、
    #      稼働していたものは必ず止めてから起動し直す。
    if [[ -f "$SNAP/units" ]]; then
      local u was_a was_e cur_e
      while read -r u was_a was_e; do
        [[ -n "$u" ]] || continue
        systemctl stop "$u" >/dev/null 2>&1 || true
        if [[ "$was_a" -eq 1 ]]; then
          if systemctl start "$u" >/dev/null 2>&1 && wait_active "$u" 15; then
            echo "  ✓ $u を元の稼働状態（active）に戻しました" >&2
          else
            echo "  ! $u を元の稼働状態に戻せませんでした" >&2
            bad=1
          fi
        fi
        # 有効化状態も戻す
        cur_e=0; systemctl is-enabled --quiet "$u" 2>/dev/null && cur_e=1
        if [[ "$was_e" -ne "$cur_e" ]]; then
          if [[ "$was_e" -eq 1 ]]; then
            systemctl enable "$u" >/dev/null 2>&1 || { echo "  ! $u を enable できませんでした" >&2; bad=1; }
          else
            systemctl disable "$u" >/dev/null 2>&1 || { echo "  ! $u を disable できませんでした" >&2; bad=1; }
          fi
        fi
      done < "$SNAP/units"
    fi
  fi

  # 3) 既存の caddy.service を元通りに
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
      bad=1
    fi
  fi

  # 復元に失敗したらスナップショットを残す（手動復旧の唯一の材料になる）
  if [[ "$bad" -eq 0 ]]; then
    [[ -n "$SNAP" ]] && rm -rf "$SNAP"
  else
    echo "  ! 旧ファイルの退避を残しました: ${SNAP}" >&2
    echo "  ! 手動で戻す場合: cp -a ${SNAP}/keep/... /元のパス   （ファイル名はパスの / を _ に置換）" >&2
  fi
  return "$bad"
}

# 切り替え失敗の共通出口: 復元できたかでメッセージと終了コードを変える
switch_fail() {          # <理由> <案内>
  local why="$1" hint="${2:-}"
  if restore_switch "$why"; then
    echo "エラー: ${why}（元の状態に戻しました）${hint:+。$hint}" >&2
    exit 1
  else
    echo "エラー: ${why}。さらに復元にも失敗しました。手動での復旧が必要です。" >&2
    echo "       systemctl status caddy.service caddy-native / sudo ss -ltnp | grep :443" >&2
    exit 3
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  local keep=0
  if [[ "$SWITCH_STARTED" -eq 1 && "$SWITCH_DONE" -eq 0 ]]; then
    if restore_switch "予期しない失敗（終了コード ${rc}）"; then
      rc=1
    else
      rc=3
    fi
  fi
  # 復元に失敗した（exit 3）ときは、復旧材料としてスナップショットを残す
  [[ "$rc" -eq 3 ]] && keep=1
  if [[ "$keep" -eq 0 && -n "$SNAP" && -d "$SNAP" ]]; then rm -rf "$SNAP"; fi
  [[ "$keep" -eq 1 && -n "$SNAP" && -d "$SNAP" ]] && \
    echo "  ! 退避を残しました: ${SNAP}（手動復旧に使ってください）" >&2
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
#   対象は install.sh に申告させる（--list-targets）。ここで一覧を書くと必ずズレる。
SNAP="$(mktemp -d /tmp/caddy-switch.XXXXXX)"
mkdir -p "$SNAP/keep" "$SNAP/existed"
TARGETS_FILE="$SNAP/targets"
( cd "$REPO_DIR/ec2" && ./install.sh --list-targets ) > "$TARGETS_FILE" \
  || die "install.sh --list-targets に失敗しました（退避対象を決められません）"
# この script 自身が書き込む unit も対象に加える
echo /etc/systemd/system/caddy-native.service >> "$TARGETS_FILE"
sort -u -o "$TARGETS_FILE" "$TARGETS_FILE"

: > "$SNAP/newdirs"
while IFS= read -r _t; do
  [[ -n "$_t" ]] || continue
  _key="$(printf '%s' "$_t" | tr '/' '_')"
  if [[ -e "$_t" ]]; then
    cp -a "$_t" "$SNAP/keep/$_key" || die "退避に失敗しました: $_t"
    : > "$SNAP/existed/$_key"
  fi
  _d="$(dirname "$_t")"
  [[ -d "$_d" ]] || echo "$_d" >> "$SNAP/newdirs"
done < "$TARGETS_FILE"

if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
  systemctl is-active  --quiet caddy.service 2>/dev/null && LEGACY_WAS_ACTIVE=1
  systemctl is-enabled --quiet caddy.service 2>/dev/null && LEGACY_WAS_ENABLED=1
fi

# --- サービス（ユニット）の稼働状態も退避 --------------------------------------
#   install.sh は caddy-native / pi-web を再起動し、timer を enable --now する。
#   ここで状態を控えておかないと、切り替えに失敗してファイルだけ戻しても
#   「新しい設定を読んだまま動いているプロセス」が残る（ファイルと状態が食い違う）。
UNITS_TO_RESTORE=(caddy-native.service pi-web pi-web-duckdns.timer)
: > "$SNAP/units"
for _u in "${UNITS_TO_RESTORE[@]}"; do
  _a=0; _e=0
  systemctl is-active  --quiet "$_u" 2>/dev/null && _a=1
  systemctl is-enabled --quiet "$_u" 2>/dev/null && _e=1
  printf '%s %s %s\n' "$_u" "$_a" "$_e" >> "$SNAP/units"
done
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

systemctl daemon-reload || switch_fail "daemon-reload に失敗" "systemctl status を確認してください"

# 既存サービスを止める（ここから先は失敗時に元へ戻す）
if [[ "$LEGACY_WAS_ACTIVE" -eq 1 ]]; then
  if systemctl disable --now caddy.service; then
    ok "既存の caddy.service を停止・無効化"
    sleep 1
  else
    switch_fail "既存の caddy.service を停止できない" "何も変更できていません"
  fi
fi

# 自分自身（caddy-native）が 443 を持っている場合は、一度止めてから占有チェックする。
# 再実行時に「443 が使用中」と誤判定して必ず失敗するのを防ぐ（状態は退避済み）。
if systemctl is-active --quiet caddy-native.service 2>/dev/null; then
  ok "稼働中の caddy-native を一度停止（再起動はこの後）"
  systemctl stop caddy-native.service || switch_fail "caddy-native を停止できない" "systemctl status caddy-native を確認してください"
  sleep 1
fi

# 443 がまだ埋まっているなら別プロセス（Docker 版など）が掴んでいる
if command -v ss >/dev/null && ss -ltn 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}'; then
  switch_fail "443 が他のプロセスに使われている" \
    "Docker 版 Caddy が動いている場合は cd ${REPO_DIR}/duckdns && docker compose down、占有元は sudo ss -ltnp | grep :443"
fi

if ! systemctl enable --now caddy-native.service; then
  systemctl --no-pager --lines=15 status caddy-native.service || true
  switch_fail "caddy-native.service を起動できない" "journalctl -u caddy-native を確認してください"
fi

# Type=simple は起動直後に落ちても成功を返すので、active になるまで待つ
ACTIVE=0
for i in $(seq 1 15); do
  systemctl is-active --quiet caddy-native.service && { ACTIVE=1; break; }
  sleep 1
done
if [[ "$ACTIVE" -eq 0 ]]; then
  systemctl --no-pager --lines=15 status caddy-native.service || true
  switch_fail "caddy-native.service が 15 秒以内に active にならない" "journalctl -u caddy-native を確認してください"
fi

# 443 を実際に掴めているか（証明書取得前でも LISTEN はする）
if command -v ss >/dev/null && ! ss -ltn 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}'; then
  switch_fail "caddy-native は起動したが 443 を LISTEN していない" "sudo ss -ltnp | grep :443 を確認してください"
fi

SWITCH_DONE=1
ok "caddy-native.service 起動（active / 443 LISTEN を確認）"

echo "[5/5] 確認先の案内..."
# 取れなくても止まらない（pipefail で落ちないように）
DOMAIN="$(grep -E '^DUCKDNS_DOMAIN=' "$REPO_DIR/duckdns/.env.caddy" 2>/dev/null | cut -d= -f2- || true)"
DOMAIN="${DOMAIN:-<ドメイン>}"
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
