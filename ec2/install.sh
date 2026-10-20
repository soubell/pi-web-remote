#!/usr/bin/env bash
# ec2/.env の 1 ファイルから設定を配布する（EC2 + ネイティブ Caddy + DuckDNS 前提）
#
#   cd ec2
#   cp .env.example .env && nano .env     # 値を埋める
#   sudo ./install.sh                     # 反映（--dry-run でプレビュー）
#
# 配布は 2 フェーズ:
#   STAGE  : すべての設定を一時ディレクトリに生成し、検証まで済ませる
#   COMMIT : 検証がすべて通ってから本番へ置き換え、サービスを再起動する
#            どこかで失敗したら「ファイル・所有者/権限・サービス状態」をまとめて元に戻す
#
# 標準構成は EC2 + ネイティブ Caddy（Docker なし）。Docker 版 Caddy を使う場合のみ
# --with-docker-caddy を明示する。
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
WITH_DOCKER=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=1 ;;
    --with-docker-caddy)  WITH_DOCKER=1 ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "エラー: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
warn(){ echo "  ! $*" >&2; }

STAGE=""
CLEANUP_PATHS=()
cleanup() {
  local p
  for p in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do
    [[ -n "$p" && -e "$p" ]] && rm -rf "$p"
  done
}
trap cleanup EXIT

# --- 0) 前提 ----------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
  [[ $EUID -eq 0 ]] || die "sudo で実行してください: sudo $0"
fi
[[ -f ./.env ]] || die "$(pwd)/.env がありません。cp .env.example .env して値を入れてください"

# --- 1) .env を「許可したキーだけ」データとして読む ---------------------------
#   ・source しない（値をシェルとして実行しない）
#   ・許可リストに無いキーは無視する（PATH などを書き換えられないようにする）
PROVIDER_KEYS=(
  ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY
  DEEPSEEK_API_KEY XAI_API_KEY GROQ_API_KEY MISTRAL_API_KEY
  MOONSHOT_API_KEY KIMI_API_KEY AI_GATEWAY_API_KEY
)
ALLOWED_KEYS=(
  DUCKDNS_DOMAIN DUCKDNS_TOKEN ACME_EMAIL
  BASIC_AUTH_USER BASIC_AUTH_PASSWORD
  PI_WEB_PASSWORD PI_WEB_IDLE_TIMEOUT_MS PI_WEB_UPSTREAM
  PI_CODING_AGENT_DIR
  "${PROVIDER_KEYS[@]}"
)
is_allowed() {
  local k="$1" a
  for a in "${ALLOWED_KEYS[@]}"; do [[ "$k" == "$a" ]] && return 0; done
  return 1
}

UNKNOWN_KEYS=()
while IFS= read -r _line || [[ -n "$_line" ]]; do
  _line="${_line%$'\r'}"
  [[ "$_line" =~ ^[[:space:]]*(#|$) ]] && continue
  _line="${_line#"${_line%%[![:space:]]*}"}"
  _line="${_line#export }"
  [[ "$_line" == *=* ]] || continue
  _key="${_line%%=*}"; _val="${_line#*=}"
  _key="${_key//[[:space:]]/}"
  [[ "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  if [[ "$_val" =~ ^\"(.*)\"$ ]] || [[ "$_val" =~ ^\'(.*)\'$ ]]; then
    _val="${BASH_REMATCH[1]}"
  else
    _val="${_val%"${_val##*[![:space:]]}"}"
  fi
  if is_allowed "$_key"; then
    printf -v "$_key" '%s' "$_val"
  else
    UNKNOWN_KEYS+=("$_key")
  fi
done < ./.env

[[ ${#UNKNOWN_KEYS[@]} -gt 0 ]] && \
  warn "未知のキーを無視しました: ${UNKNOWN_KEYS[*]}（ec2/.env.example を参照）"

# --- 2) 検証 ----------------------------------------------------------------
: "${DUCKDNS_DOMAIN:?DUCKDNS_DOMAIN が空です}"
: "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN が空です}"
: "${BASIC_AUTH_PASSWORD:?BASIC_AUTH_PASSWORD が空です}"
: "${PI_WEB_PASSWORD:?PI_WEB_PASSWORD が空です}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-pi}"
ACME_EMAIL="${ACME_EMAIL:-acme@${DUCKDNS_DOMAIN}}"
PI_WEB_IDLE_TIMEOUT_MS="${PI_WEB_IDLE_TIMEOUT_MS:-0}"
PI_WEB_UPSTREAM="${PI_WEB_UPSTREAM:-127.0.0.1:30141}"

[[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || die "ACME_EMAIL の形式が不正: $ACME_EMAIL"
[[ "$DUCKDNS_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.duckdns\.org$ ]] || \
  die "DUCKDNS_DOMAIN の形式が不正: $DUCKDNS_DOMAIN（例: mypi.duckdns.org）"
[[ "$DUCKDNS_TOKEN" =~ ^[A-Za-z0-9-]{8,64}$ ]] || die "DUCKDNS_TOKEN の形式が不正（8〜64 文字の英数字とハイフン）"
[[ "$BASIC_AUTH_USER" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "BASIC_AUTH_USER の形式が不正"
[[ ${#BASIC_AUTH_PASSWORD} -ge 12 ]] || die "BASIC_AUTH_PASSWORD は 12 文字以上にしてください"
[[ ${#PI_WEB_PASSWORD}   -ge 16 ]] || die "PI_WEB_PASSWORD は 16 文字以上にしてください"
[[ "$BASIC_AUTH_PASSWORD" != "$PI_WEB_PASSWORD" ]] || die "2 つのパスワードは別の値にしてください"
for _pw in "$BASIC_AUTH_PASSWORD" "$PI_WEB_PASSWORD"; do
  [[ "$_pw" =~ [[:space:]\"\'\$\\#\;] ]] && \
    die "パスワードに空白・引用符・\$・#・; は使えません（systemd/Caddyfile が壊れます）。openssl rand -base64 32 を使ってください"
done
id -u piweb &>/dev/null || die "ユーザー piweb がありません（user-data.sh か手動で作成してください）"
[[ -f /etc/systemd/system/caddy-native.service ]] || \
  die "caddy-native.service がありません。先に sudo ./install-caddy-native.sh を実行してください"
NATIVE=1
# 初回導入かどうかで事後確認の厳しさを変える（初回は証明書取得待ちを許容する）
CADDY_WAS_ACTIVE=0
systemctl is-active --quiet caddy-native 2>/dev/null && CADDY_WAS_ACTIVE=1

# --- 3) bcrypt ハッシュ ------------------------------------------------------
echo "[1/6] Basic 認証のハッシュを生成..."
hash_password() {
  local pw="$1"
  if command -v caddy >/dev/null 2>&1; then
    printf '%s' "$pw" | caddy hash-password
    return
  fi
  if ! command -v htpasswd >/dev/null 2>&1; then
    echo "  htpasswd を導入（apache2-utils）..." >&2
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq apache2-utils >/dev/null 2>&1 || true
  fi
  command -v htpasswd >/dev/null 2>&1 || die "bcrypt を作れません。caddy か apache2-utils を入れてください"
  htpasswd -nbB -C 14 "${BASIC_AUTH_USER}" "$pw" | cut -d: -f2- | sed 's/^\$2y\$/$2a$/'
}

if [[ $DRY_RUN -eq 1 ]]; then
  BASIC_AUTH_HASH='$2a$14$<dry-run では生成しません>'
  ok "bcrypt 生成はスキップ（--dry-run）"
else
  BASIC_AUTH_HASH="$(hash_password "$BASIC_AUTH_PASSWORD" | tr -d '\r')"
  [[ "$BASIC_AUTH_HASH" == \$2[aby]\$* ]] || die "ハッシュ生成に失敗: $BASIC_AUTH_HASH"
  ok "bcrypt 生成"
fi

# --- 4) dry-run はここで終了 --------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] このモードでは書き込み・パッケージ導入を行いません"
  cat <<EOF
[dry-run] 書き込み予定（パスワードは伏字）:
  ../duckdns/.env.caddy
    DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
    DUCKDNS_API_TOKEN=***
    ACME_EMAIL=${ACME_EMAIL}
    BASIC_AUTH_USER=${BASIC_AUTH_USER}
    BASIC_AUTH_HASH=${BASIC_AUTH_HASH:0:7}***
    PI_WEB_UPSTREAM=${PI_WEB_UPSTREAM}
  /etc/pi-web/caddy.env     （root:caddy 0640。検証後に反映）
  /etc/pi-web/Caddyfile     （0644。検証後に反映）
  /etc/pi-web/duckdns.env
    DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
    DUCKDNS_TOKEN=***
  /home/piweb/.config/pi-web/env
    PI_WEB_PASSWORD=***
    PI_WEB_ALLOWED_HOSTS=${DUCKDNS_DOMAIN}
    PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS}
    PI_WEB_NO_OPEN=1
[dry-run] 検証 → 一括置換 → 再起動 → 事後確認。失敗時はファイル・権限・サービスを全て復元
EOF
  exit 0
fi

# ============================================================================
# STAGE フェーズ: 本番には一切触らず、すべて一時ディレクトリに生成して検証する
# ============================================================================
echo "[2/6] 設定を生成して検証中（本番ファイルはまだ触りません）..."
STAGE="$(mktemp -d /tmp/pi-web-install.XXXXXX)"
CLEANUP_PATHS+=("$STAGE")
umask 077

# (a) リポジトリ内の .env.caddy（記録用）
cat > "$STAGE/env.caddy" <<EOF
DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
DUCKDNS_API_TOKEN=${DUCKDNS_TOKEN}
ACME_EMAIL=${ACME_EMAIL}
BASIC_AUTH_USER=${BASIC_AUTH_USER}
BASIC_AUTH_HASH=${BASIC_AUTH_HASH}
PI_WEB_UPSTREAM=${PI_WEB_UPSTREAM}
EOF

# (b) DuckDNS 更新スクリプト用
cat > "$STAGE/duckdns.env" <<EOF
DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
EOF

# (c) Pi Web 用
cat > "$STAGE/piweb.env" <<EOF
PI_WEB_PASSWORD=${PI_WEB_PASSWORD}
PI_WEB_ALLOWED_HOSTS=${DUCKDNS_DOMAIN}
PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS}
PI_WEB_NO_OPEN=1
EOF
PASSED=()
for k in "${PROVIDER_KEYS[@]}"; do
  v="${!k:-}"
  [[ -n "$v" ]] && { printf '%s=%s\n' "$k" "$v" >> "$STAGE/piweb.env"; PASSED+=("$k"); }
done
if [[ -n "${PI_CODING_AGENT_DIR:-}" ]]; then
  printf 'PI_CODING_AGENT_DIR=%s\n' "$PI_CODING_AGENT_DIR" >> "$STAGE/piweb.env"
  PASSED+=("PI_CODING_AGENT_DIR")
fi

# (d) ネイティブ Caddy 用。検証は必ず行う（fail-closed）
cp "$STAGE/env.caddy" "$STAGE/caddy.env"
cp ../duckdns/Caddyfile.native "$STAGE/Caddyfile"
chmod 640 "$STAGE/caddy.env"; chmod 644 "$STAGE/Caddyfile"
command -v caddy >/dev/null 2>&1 || \
  die "caddy コマンドが見つかりません。安全に検証できないため中止します（設定は変更していません）"
if ! (
  while IFS= read -r _l || [[ -n "$_l" ]]; do
    _l="${_l%$'\r'}"
    [[ "$_l" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$_l" == *=* ]] || continue
    _k="${_l%%=*}"; _v="${_l#*=}"
    printf -v "$_k" '%s' "$_v"; export "${_k?}"
  done < "$STAGE/caddy.env"
  caddy validate --config "$STAGE/Caddyfile" >/dev/null
); then
  die "Caddyfile の検証に失敗しました。設定は一切変更していません"
fi
ok "caddy validate（一時ファイル上で検証）"

# (e) 外向き通信の事前確認（API キーを入れたのに到達できない事故を防ぐ）
PROBE_HOST=""
for k in "${PASSED[@]}"; do
  case "$k" in
    ANTHROPIC_API_KEY) PROBE_HOST="api.anthropic.com" ;;
    OPENAI_API_KEY)    PROBE_HOST="${PROBE_HOST:-api.openai.com}" ;;
    GEMINI_API_KEY)    PROBE_HOST="${PROBE_HOST:-generativelanguage.googleapis.com}" ;;
    OPENROUTER_API_KEY) PROBE_HOST="${PROBE_HOST:-openrouter.ai}" ;;
  esac
done
if [[ -n "$PROBE_HOST" ]]; then
  if timeout 8 bash -c "exec 3<>/dev/tcp/${PROBE_HOST}/443" 2>/dev/null; then
    ok "外向き 443 到達確認（${PROBE_HOST}）"
  else
    die "${PROBE_HOST}:443 に到達できません。セキュリティグループのアウトバウンドか DNS を確認してください（設定は変更していません）"
  fi
fi
ok "設定を生成（${STAGE}）"

# ============================================================================
# COMMIT フェーズ
# ============================================================================
echo "[3/6] 設定を反映..."
BACKUP_DIR="$STAGE/bak"; mkdir -p "$BACKUP_DIR"
COMMITTED=()            # "dest|backup"（backup が空なら「新規作成」＝ロールバックで削除）
STARTED_UNITS=()        # 旧設定で起動し直す必要があるユニット（依存順）
ROLLBACK_FAILED=0

commit_file() {         # <src> <dest> <mode> [owner]
  local src="$1" dest="$2" mode="$3" owner="${4:-}" bak=""
  if [[ -e "$dest" ]]; then
    bak="$BACKUP_DIR/$(echo "$dest" | tr '/' '_')"
    cp -a "$dest" "$bak"
  fi
  install -d -m 755 "$(dirname "$dest")"
  if [[ -n "$owner" ]]; then
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dest" 2>/dev/null \
      || install -m "$mode" "$src" "$dest"
  else
    install -m "$mode" "$src" "$dest"
  fi
  COMMITTED+=("$dest|$bak")
}

# 復元: cp -a で所有者・グループ・モード・時刻まで含めて戻す
# サービスが「本当に動いているか」を待って確認する（Type=simple は直後に落ちても
# start/restart が成功を返すため、戻り値だけでは足りない）
wait_active() {          # <unit> <待ち秒>
  local unit="$1" want="${2:-15}" i
  for (( i=0; i<want; i++ )); do
    systemctl is-active --quiet "$unit" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

rollback_state() {
  local reason="$1" entry dest bak u i rc=0
  warn "反映に失敗したため元に戻します（理由: ${reason}）"

  # 1) 新設定で動いているサービスを止める（動いたまま古いファイルに戻すと不整合になる）
  #    停止できなかったサービスがあると「新設定のプロセス＋旧ファイル」になり得るので、
  #    失敗は握りつぶさず復元失敗として扱う。
  for u in ${STARTED_UNITS[@]+"${STARTED_UNITS[@]}"}; do
    if ! systemctl stop "$u" >/dev/null 2>&1; then
      # 既に停止している場合も stop は成功するので、ここに来るのは異常
      warn "$u を停止できませんでした（新設定のまま動いている可能性）"
      rc=1
    fi
  done

  # 2) ファイル復元（所有者・権限ごと）
  for entry in ${COMMITTED[@]+"${COMMITTED[@]}"}; do
    dest="${entry%%|*}"; bak="${entry##*|}"
    if [[ -n "$bak" && -f "$bak" ]]; then
      if ! cp -a "$bak" "$dest" 2>/dev/null; then
        warn "復元に失敗しました: $dest"
        rc=1
      fi
    else
      rm -f "$dest" 2>/dev/null || { warn "削除に失敗しました: $dest"; rc=1; }
    fi
  done

  # 3) unit を読み直し、旧設定で起動し直す（依存の逆順 = pi-web → caddy-native）
  if ! systemctl daemon-reload >/dev/null 2>&1; then
    warn "daemon-reload に失敗（unit の変更が反映されていない可能性）"
    rc=1
  fi
  for (( i=${#STARTED_UNITS[@]}-1; i>=0; i-- )); do
    u="${STARTED_UNITS[$i]}"
    if systemctl start "$u" >/dev/null 2>&1 && wait_active "$u" 15; then
      ok "$u を旧設定で起動（active を確認）"
    else
      warn "$u を旧設定で起動できませんでした（要手動確認）"
      rc=1
    fi
  done

  if [[ "$rc" -eq 1 ]]; then
    warn "完全な復元に失敗しています。sudo ./check.sh と journalctl -u caddy-native / -u pi-web を確認してください"
  else
    ok "設定・権限・サービスを元の状態に復元しました（${#COMMITTED[@]} ファイル）"
  fi
  return "$rc"
}

# 失敗時の共通出口。ロールバックの成否でメッセージと終了コードを変える
fail_install() {         # <理由> <補足の確認先>
  local reason="$1" hint="${2:-}"
  if rollback_state "$reason"; then
    echo "エラー: ${reason}（設定は元に戻しました）${hint:+。$hint}" >&2
    exit 1
  else
    echo "エラー: ${reason}。さらに復元にも失敗しました。手動での復旧が必要です。" >&2
    echo "       sudo ./check.sh / systemctl status caddy-native pi-web / journalctl -xe" >&2
    exit 3
  fi
}

commit_file "$STAGE/env.caddy"     "../duckdns/.env.caddy" 600
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" ../duckdns/.env.caddy 2>/dev/null || true
fi
ok "../duckdns/.env.caddy"

commit_file "$STAGE/duckdns.env"   "/etc/pi-web/duckdns.env" 600
ok "/etc/pi-web/duckdns.env"

if getent group caddy >/dev/null 2>&1; then
  commit_file "$STAGE/caddy.env" "/etc/pi-web/caddy.env" 640 "root:caddy"
else
  commit_file "$STAGE/caddy.env" "/etc/pi-web/caddy.env" 600
fi
commit_file "$STAGE/Caddyfile"   "/etc/pi-web/Caddyfile" 644
ok "/etc/pi-web/caddy.env（root:caddy 0640）+ Caddyfile"

commit_file "$STAGE/piweb.env" "/home/piweb/.config/pi-web/env" 600 "piweb:piweb"
ok "/home/piweb/.config/pi-web/env"
[[ ${#PASSED[@]} -gt 0 ]] && ok "プロバイダ設定を引き継ぎ: ${PASSED[*]}"
chmod 600 ./.env

# --- 4) systemd ユニット -----------------------------------------------------
echo "[4/6] systemd ユニットを配置..."
install -m 755 update-duckdns.sh /usr/local/bin/pi-web-duckdns-update
REPO_DIR="$(cd .. && pwd)"
for u in pi-web-duckdns.service pi-web-duckdns.timer pi-web.service; do
  [[ -f "$u" ]] || continue
  sed "s#@REPO_DIR@#${REPO_DIR}/duckdns#g" "$u" > "$STAGE/$u"
  chmod 644 "$STAGE/$u"
  commit_file "$STAGE/$u" "/etc/systemd/system/$u" 644
  ok "/etc/systemd/system/$u"
done
systemctl daemon-reload

# --- 5) サービス再起動（依存順）+ 稼働確認 ------------------------------------
echo "[5/6] サービスを再起動..."
# Type=simple のサービスは restart の戻り値だけでは「直後に落ちた」ことを見逃すので、
# is-active が active になるまで少し待って確認する
restart_unit() {         # <unit> <待ち秒>
  local unit="$1" want="${2:-15}"
  STARTED_UNITS+=("$unit")
  if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
    ok "$unit は停止中（次回起動時に反映）"
    return 0
  fi
  if ! systemctl restart "$unit" >/dev/null 2>&1; then
    fail_install "$unit の再起動コマンドが失敗" "journalctl -u $unit を確認してください"
  fi
  if ! wait_active "$unit" "$want"; then
    fail_install "$unit が ${want} 秒以内に active にならない" "journalctl -u $unit を確認してください"
  fi
  ok "$unit を再起動して反映（active を確認）"
}

restart_unit caddy-native 15
restart_unit pi-web 15
systemctl enable --now pi-web-duckdns.timer >/dev/null 2>&1 && ok "pi-web-duckdns.timer 有効化"

# --- 6) 事後確認（ローカルから実際に叩く） --------------------------------------
echo "[6/6] 反映後の確認..."
sleep 1
VERIFIED="unverified"
if systemctl is-active --quiet caddy-native 2>/dev/null; then
  CODE=""
  for i in 1 2 3; do
    if CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
        --resolve "${DUCKDNS_DOMAIN}:443:127.0.0.1" "https://${DUCKDNS_DOMAIN}/" 2>/dev/null)"; then :; else CODE="000"; fi
    [[ "$CODE" != "000" ]] && break
    [[ "$i" -lt 3 ]] && sleep 3
  done
  case "$CODE" in
    200|301|302|401)
      ok "ローカル HTTPS 応答 ${CODE}（Caddy → Pi Web 疎通）"
      VERIFIED="verified"
      ;;
    502|503|504)
      # Caddy は動いているが Pi Web に届かない = 確実に異常
      fail_install "Caddy から Pi Web に到達できない（HTTP ${CODE}）" "journalctl -u pi-web を確認してください"
      ;;
    *)
      # 000（証明書がまだ無い / TLS 失敗）や想定外のコード
      if [[ "$CADDY_WAS_ACTIVE" -eq 0 ]]; then
        warn "ローカル HTTPS 応答 ${CODE}（初回導入のため証明書取得待ちと判断）"
        warn "数分後に https://${DUCKDNS_DOMAIN}/ を開いて確認してください。未確認のまま終了します"
        VERIFIED="pending-cert"
      else
        # 既に動いていた構成の更新で応答が壊れた = 異常。旧設定に戻す
        fail_install "更新後に HTTPS が正常応答しない（HTTP ${CODE}）" "journalctl -u caddy-native を確認してください"
      fi
      ;;
  esac
fi

# --- Docker 版 Caddy は明示指定時のみ ------------------------------------------
if [[ "$WITH_DOCKER" -eq 1 ]]; then
  if ( cd ../duckdns && docker compose up -d >/dev/null 2>&1 ); then
    ok "Docker 版 Caddy を再作成して反映"
  else
    rollback_state "Docker 版 Caddy の再作成に失敗"
    die "Docker 版 Caddy の反映に失敗しました（設定は元に戻しました）。cd ../duckdns && docker compose up -d で確認してください"
  fi
elif [[ -f ../duckdns/docker-compose.yml ]] && command -v docker >/dev/null 2>&1 \
     && docker ps --format '{{.Names}}' 2>/dev/null | grep -q caddy; then
  warn "Docker 版 Caddy のコンテナが動いていますが、標準構成（ネイティブ Caddy）では更新しません"
  warn "Docker 版を使う場合は --with-docker-caddy を付けてください"
fi

# --- 7) 初回の DuckDNS 更新 ---------------------------------------------------
if /usr/local/bin/pi-web-duckdns-update; then
  ok "DuckDNS を現在の IP に更新"
else
  warn "DuckDNS の更新に失敗しました。トークンとアウトバウンド 443 を確認してください"
fi

# 成功したのでバックアップを破棄
COMMITTED=()
if [[ "$VERIFIED" == "verified" ]]; then
  RESULT="完了（HTTPS 応答まで確認済み）"
elif [[ "$VERIFIED" == "pending-cert" ]]; then
  RESULT="完了（ただし HTTPS は未確認: 証明書取得待ち。数分後にブラウザで確認）"
else
  RESULT="完了（HTTPS は未確認）"
fi
cat <<MSG

${RESULT}
配布内容は ec2/.env の 1 ファイルが正である。

設定を変えたいとき:
  nano $(pwd)/.env   →   sudo ./install.sh
  （検証してから一括反映し、どこかで失敗したらファイル・権限・サービスを全て元に戻す）

確認:
  sudo ./check.sh
MSG
