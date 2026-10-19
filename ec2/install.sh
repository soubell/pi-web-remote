#!/usr/bin/env bash
# ec2/.env の 1 ファイルから、各サービスの環境変数を配布し、systemd ユニットを配置する
#
#   cd ec2
#   cp .env.example .env && nano .env     # 値を埋める
#   sudo ./install.sh                     # 配布（--dry-run でプレビュー）
#
# 配布は「2 フェーズ」で行う:
#   STAGE  : すべての設定を一時ディレクトリに生成し、Caddy の検証まで済ませる
#   COMMIT : 検証がすべて通ってから本番へ置き換える（失敗したら全部ロールバック）
# 途中で失敗しても、稼働中の設定が「一部だけ新しい」状態にはならない。
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

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
SUB="${DUCKDNS_DOMAIN%.duckdns.org}"

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

NATIVE=0
[[ -f /etc/systemd/system/caddy-native.service ]] && NATIVE=1

# --- 3) bcrypt ハッシュ ------------------------------------------------------
echo "[1/5] Basic 認証のハッシュを生成..."
hash_password() {
  local pw="$1"
  if command -v caddy >/dev/null 2>&1; then
    printf '%s' "$pw" | caddy hash-password
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf '%s' "$pw" | docker run -i --rm caddy:2.11 caddy hash-password
  else
    if ! command -v htpasswd >/dev/null 2>&1; then
      echo "  htpasswd を導入（apache2-utils）..." >&2
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq apache2-utils >/dev/null 2>&1 || true
    fi
    command -v htpasswd >/dev/null 2>&1 || die "bcrypt を作れません。caddy / docker / apache2-utils のいずれかを入れてください"
    htpasswd -nbB -C 14 "${BASIC_AUTH_USER}" "$pw" | cut -d: -f2- | sed 's/^\$2y\$/$2a$/'
  fi
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
  echo "[dry-run] このモードでは書き込み・パッケージ導入・イメージ取得を行いません"
  cat <<EOF
[dry-run] 書き込み予定（パスワードは伏字）:
  ../duckdns/.env.caddy
    DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
    DUCKDNS_API_TOKEN=***
    ACME_EMAIL=${ACME_EMAIL}
    BASIC_AUTH_USER=${BASIC_AUTH_USER}
    BASIC_AUTH_HASH=${BASIC_AUTH_HASH:0:7}***
    PI_WEB_UPSTREAM=${PI_WEB_UPSTREAM}
  /etc/pi-web/caddy.env      （ネイティブ Caddy が導入済みの場合のみ。検証後に反映）
  /etc/pi-web/duckdns.env
    DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
    DUCKDNS_TOKEN=***
  /home/piweb/.config/pi-web/env
    PI_WEB_PASSWORD=***
    PI_WEB_ALLOWED_HOSTS=${DUCKDNS_DOMAIN}
    PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS}
    PI_WEB_NO_OPEN=1
[dry-run] すべて検証が通ってから一括で置き換えます（失敗時は何も変更しません）
EOF
  exit 0
fi

# ============================================================================
# STAGE フェーズ: 本番には一切触らず、すべて一時ディレクトリに生成して検証する
# ============================================================================
echo "[2/5] 設定を生成して検証中（本番ファイルはまだ触りません）..."
STAGE="$(mktemp -d /tmp/pi-web-install.XXXXXX)"
CLEANUP_PATHS+=("$STAGE")
umask 077

# (a) リポジトリ内の .env.caddy（Docker 版 Caddy / 記録用）
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

# (d) ネイティブ Caddy 用（導入済みの場合のみ）。検証は必ず行う（fail-closed）
if [[ "$NATIVE" -eq 1 ]]; then
  cp "$STAGE/env.caddy" "$STAGE/caddy.env"
  cp ../duckdns/Caddyfile.native "$STAGE/Caddyfile"
  command -v caddy >/dev/null 2>&1 || \
    die "caddy-native.service があるのに caddy コマンドが見つかりません。安全に検証できないため中止します（設定は変更していません）"
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
fi
ok "設定を生成（${STAGE}）"

# ============================================================================
# COMMIT フェーズ: ここから本番へ反映。失敗したら BACKUPS で全部戻す
# ============================================================================
echo "[3/5] 設定を反映..."
BACKUP_DIR="$STAGE/bak"; mkdir -p "$BACKUP_DIR"
COMMITTED=()          # 復元対象（"dest|backup or EMPTY"）
commit_file() {       # <src> <dest> <mode> [owner]
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

rollback() {
  local entry dest bak
  warn "反映に失敗したため、設定を元に戻します"
  for entry in ${COMMITTED[@]+"${COMMITTED[@]}"}; do
    dest="${entry%%|*}"; bak="${entry##*|}"
    if [[ -n "$bak" && -f "$bak" ]]; then
      install -m 600 "$bak" "$dest" 2>/dev/null || cp -a "$bak" "$dest" || true
    else
      rm -f "$dest" || true
    fi
  done
  warn "復元しました: ${#COMMITTED[@]} ファイル"
}

commit_file "$STAGE/env.caddy"     "../duckdns/.env.caddy" 600
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" ../duckdns/.env.caddy 2>/dev/null || true
fi
ok "../duckdns/.env.caddy"

commit_file "$STAGE/duckdns.env"   "/etc/pi-web/duckdns.env" 600
ok "/etc/pi-web/duckdns.env"

if id -u piweb &>/dev/null; then
  commit_file "$STAGE/piweb.env" "/home/piweb/.config/pi-web/env" 600 "piweb:piweb"
else
  commit_file "$STAGE/piweb.env" "/home/piweb/.config/pi-web/env" 600
fi
ok "/home/piweb/.config/pi-web/env"
[[ ${#PASSED[@]} -gt 0 ]] && ok "プロバイダ設定を引き継ぎ: ${PASSED[*]}"

if [[ "$NATIVE" -eq 1 ]]; then
  if getent group caddy >/dev/null 2>&1; then
    commit_file "$STAGE/caddy.env" "/etc/pi-web/caddy.env" 640 "root:caddy"
  else
    commit_file "$STAGE/caddy.env" "/etc/pi-web/caddy.env" 600
  fi
  commit_file "$STAGE/Caddyfile"   "/etc/pi-web/Caddyfile" 644
  ok "/etc/pi-web/caddy.env + Caddyfile（ネイティブ Caddy）"
fi

chmod 600 ./.env

# --- サービス再起動（失敗したら設定ごとロールバック） --------------------------
restart_or_rollback() {   # <unit>
  local unit="$1"
  systemctl is-active --quiet "$unit" 2>/dev/null || { ok "$unit は停止中（次回起動時に反映）"; return 0; }
  if systemctl restart "$unit"; then
    ok "$unit を再起動して反映"
  else
    rollback
    systemctl restart "$unit" 2>/dev/null || true    # 旧設定で復旧を試みる
    die "$unit の再起動に失敗しました（設定は元に戻しました）。journalctl -u $unit を確認してください"
  fi
}

if [[ "$NATIVE" -eq 1 ]]; then
  restart_or_rollback caddy-native
fi

# --- 5) systemd ユニット ----------------------------------------------------
echo "[4/5] systemd ユニットを配置..."
install -m 755 update-duckdns.sh /usr/local/bin/pi-web-duckdns-update
REPO_DIR="$(cd .. && pwd)"
UNITS=(pi-web-duckdns.service pi-web-duckdns.timer pi-web.service)
if command -v docker >/dev/null 2>&1; then UNITS+=(caddy.service); fi
for u in "${UNITS[@]}"; do
  [[ -f "$u" ]] || continue
  sed "s#@REPO_DIR@#${REPO_DIR}/duckdns#g" "$u" > "/etc/systemd/system/$u"
  chmod 644 "/etc/systemd/system/$u"
  ok "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now pi-web-duckdns.timer
ok "pi-web-duckdns.timer 有効化"

restart_or_rollback pi-web

# Docker 版 Caddy は env_file の変更にコンテナ再作成が要る
if [[ "$NATIVE" -eq 0 ]] && systemctl is-enabled --quiet caddy 2>/dev/null && command -v docker >/dev/null 2>&1; then
  if ( cd ../duckdns && docker compose up -d >/dev/null 2>&1 ); then
    ok "Docker 版 Caddy を再作成して反映"
  else
    warn "Docker 版 Caddy の反映に失敗。手動で: cd ../duckdns && docker compose up -d"
  fi
fi

# 成功したのでバックアップを破棄
COMMITTED=()

# --- 6) 初回の DuckDNS 更新 ---------------------------------------------------
echo "[5/5] DuckDNS を現在の IP に更新..."
if /usr/local/bin/pi-web-duckdns-update; then :; else
  warn "更新に失敗しました。トークンとアウトバウンド 443 を確認してください"
fi

cat <<MSG

完了。配布内容は ec2/.env の 1 ファイルが正である。

設定を変えたいとき:
  nano $(pwd)/.env   →   sudo ./install.sh
  （全設定を検証してから一括で反映し、失敗時はすべて元に戻す）

確認:
  sudo ./check.sh
MSG
