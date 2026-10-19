#!/usr/bin/env bash
# ec2/.env の 1 ファイルから、各サービスの環境変数を配布し、systemd ユニットを配置する
#
#   cd ec2
#   cp .env.example .env && nano .env     # 値を埋める
#   sudo ./install.sh                     # 配布（--dry-run でプレビュー）
#
# 配布先:
#   ../duckdns/.env.caddy             (Docker 版 Caddy / docker compose の env_file)
#   /etc/pi-web/caddy.env             (ネイティブ Caddy が読む。導入済みの場合のみ)
#   /etc/pi-web/duckdns.env           (root が実行する DuckDNS 更新スクリプト)
#   /home/piweb/.config/pi-web/env    (Pi Web / systemd の EnvironmentFile)
#
# 設定ファイルは「一時ファイルに書く → 検証する → 成功したら置き換える」。
# 検証に失敗した場合、稼働中の設定は一切変更しない。
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

die() { echo "エラー: $*" >&2; exit 1; }

# 異常終了しても一時ファイルを残さない
TMP_FILES=()
cleanup_tmp() {
  local f
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do [[ -n "$f" && -f "$f" ]] && rm -f "$f"; done
}
trap cleanup_tmp EXIT
ok()  { echo "  ✓ $*"; }
warn(){ echo "  ! $*" >&2; }

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
  _line="${_line%$'\r'}"                                   # CRLF 対策
  [[ "$_line" =~ ^[[:space:]]*(#|$) ]] && continue         # 空行・コメント
  _line="${_line#"${_line%%[![:space:]]*}"}"               # 先頭の空白
  _line="${_line#export }"
  [[ "$_line" == *=* ]] || continue
  _key="${_line%%=*}"; _val="${_line#*=}"
  _key="${_key//[[:space:]]/}"
  [[ "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  if [[ "$_val" =~ ^\"(.*)\"$ ]] || [[ "$_val" =~ ^\'(.*)\'$ ]]; then
    _val="${BASH_REMATCH[1]}"
  else
    _val="${_val%"${_val##*[![:space:]]}"}"                # 末尾の空白だけ落とす
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

# --- 3) bcrypt ハッシュ ------------------------------------------------------
echo "[1/4] Basic 認証のハッシュを生成..."
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
    # htpasswd -B は $2y$ を返すので $2a$ に寄せる（Caddy が確実に解釈できる形式）
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

# --- 4) dry-run はここで終了（書き込み・導入・取得をしない） ------------------
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
EOF
  [[ ${#PROVIDER_KEYS[@]} -gt 0 ]] && echo "    （.env にあるプロバイダ API キーも転記）"
  exit 0
fi

# --- 5) 配布（検証が要るものは「一時ファイル → 検証 → 置換」） ----------------
echo "[2/4] 環境変数を配布..."
umask 077

# (a) リポジトリ内の .env.caddy（Docker 版・記録用）
cat > ../duckdns/.env.caddy <<EOF
DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
DUCKDNS_API_TOKEN=${DUCKDNS_TOKEN}
ACME_EMAIL=${ACME_EMAIL}
BASIC_AUTH_USER=${BASIC_AUTH_USER}
BASIC_AUTH_HASH=${BASIC_AUTH_HASH}
PI_WEB_UPSTREAM=${PI_WEB_UPSTREAM}
EOF
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" ../duckdns/.env.caddy 2>/dev/null || true
fi
chmod 600 ../duckdns/.env.caddy
ok "../duckdns/.env.caddy"

# (b) DuckDNS 更新スクリプト（root 実行）
install -d -m 700 /etc/pi-web
cat > /etc/pi-web/duckdns.env <<EOF
DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
EOF
chmod 600 /etc/pi-web/duckdns.env
ok "/etc/pi-web/duckdns.env"

# (c) Pi Web（piweb ユーザー）
PI_WEB_ENV=/home/piweb/.config/pi-web/env
install -d -o piweb -g piweb -m 700 /home/piweb/.config/pi-web
TMP_PIWEB="$(mktemp /home/piweb/.config/pi-web/.env.XXXXXX)"; TMP_FILES+=("$TMP_PIWEB")
cat > "$TMP_PIWEB" <<EOF
PI_WEB_PASSWORD=${PI_WEB_PASSWORD}
PI_WEB_ALLOWED_HOSTS=${DUCKDNS_DOMAIN}
PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS}
PI_WEB_NO_OPEN=1
EOF
PASSED=()
for k in "${PROVIDER_KEYS[@]}"; do
  v="${!k:-}"
  [[ -n "$v" ]] && { printf '%s=%s\n' "$k" "$v" >> "$TMP_PIWEB"; PASSED+=("$k"); }
done
if [[ -n "${PI_CODING_AGENT_DIR:-}" ]]; then
  printf 'PI_CODING_AGENT_DIR=%s\n' "$PI_CODING_AGENT_DIR" >> "$TMP_PIWEB"
  PASSED+=("PI_CODING_AGENT_DIR")
fi
chown piweb:piweb "$TMP_PIWEB"; chmod 600 "$TMP_PIWEB"
if [[ -f "$PI_WEB_ENV" ]]; then cp -a "$PI_WEB_ENV" "${PI_WEB_ENV}.bak"; fi
mv -f "$TMP_PIWEB" "$PI_WEB_ENV"          # 置換は atomic
TMP_FILES=("${TMP_FILES[@]/$TMP_PIWEB}")
ok "$PI_WEB_ENV"
[[ ${#PASSED[@]} -gt 0 ]] && ok "プロバイダ設定を引き継ぎ: ${PASSED[*]}"

# ec2/.env 自体も 600 に（平文パスワードが入っているため）
chmod 600 ./.env

# --- 6) ネイティブ Caddy の設定を「検証してから」反映 --------------------------
SYNCED_CADDY=0
if [[ -f /etc/systemd/system/caddy-native.service ]]; then
  echo "[3/4] ネイティブ Caddy の設定を検証して反映..."
  install -d -m 755 /etc/pi-web
  TMP_ENV="$(mktemp /etc/pi-web/.caddy.env.XXXXXX)"; TMP_FILES+=("$TMP_ENV")
  TMP_CF="$(mktemp /etc/pi-web/.Caddyfile.XXXXXX)";  TMP_FILES+=("$TMP_CF")
  cp ../duckdns/.env.caddy "$TMP_ENV"
  cp ../duckdns/Caddyfile.native "$TMP_CF"
  if getent group caddy >/dev/null 2>&1; then chgrp caddy "$TMP_ENV" || true; fi
  chmod 640 "$TMP_ENV"; chmod 644 "$TMP_CF"

  # 検証（env はデータとして読む。source すると $2a$14$... が壊れる）
  if command -v caddy >/dev/null 2>&1; then
    if ! (
      while IFS= read -r _l || [[ -n "$_l" ]]; do
        _l="${_l%$'\r'}"
        [[ "$_l" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$_l" == *=* ]] || continue
        _k="${_l%%=*}"; _v="${_l#*=}"
        printf -v "$_k" '%s' "$_v"; export "${_k?}"
      done < "$TMP_ENV"
      caddy validate --config "$TMP_CF" >/dev/null
    ); then
      rm -f "$TMP_ENV" "$TMP_CF"
      die "Caddyfile の検証に失敗しました。稼働中の設定は変更していません（/etc/pi-web は元のまま）"
    fi
    ok "caddy validate"
  else
    warn "caddy コマンドが無いため検証をスキップしました"
  fi

  # ここまで来たら本番へ置換（mv は atomic）
  [[ -f /etc/pi-web/caddy.env ]]  && cp -a /etc/pi-web/caddy.env  /etc/pi-web/caddy.env.bak
  [[ -f /etc/pi-web/Caddyfile ]]  && cp -a /etc/pi-web/Caddyfile  /etc/pi-web/Caddyfile.bak
  mv -f "$TMP_ENV" /etc/pi-web/caddy.env
  mv -f "$TMP_CF"  /etc/pi-web/Caddyfile
  TMP_FILES=()
  ok "/etc/pi-web/caddy.env を更新（ネイティブ Caddy）"

  if systemctl is-active --quiet caddy-native 2>/dev/null; then
    if systemctl restart caddy-native; then
      rm -f /etc/pi-web/caddy.env.bak /etc/pi-web/Caddyfile.bak
      ok "caddy-native を再起動して反映"
    else
      # 起動できなければ元の設定に戻して復旧を試みる
      warn "caddy-native の再起動に失敗。設定を元に戻します"
      [[ -f /etc/pi-web/caddy.env.bak ]] && mv -f /etc/pi-web/caddy.env.bak /etc/pi-web/caddy.env
      [[ -f /etc/pi-web/Caddyfile.bak ]] && mv -f /etc/pi-web/Caddyfile.bak /etc/pi-web/Caddyfile
      systemctl restart caddy-native || true
      die "設定を元に戻しました。journalctl -u caddy-native で原因を確認してください"
    fi
  else
    ok "caddy-native は停止中のため再起動はスキップ（次回起動時に反映される）"
  fi
  SYNCED_CADDY=1
fi

# --- 7) systemd ユニット ----------------------------------------------------
echo "[4/4] systemd ユニットを配置..."
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

# --- 8) 稼働中のサービスへ反映 ------------------------------------------------
# EnvironmentFile はプロセス起動時にしか読まれないので、書き換えても再起動が要る
if systemctl is-active --quiet pi-web 2>/dev/null; then
  if systemctl restart pi-web; then
    rm -f "${PI_WEB_ENV}.bak"
    ok "pi-web を再起動して設定を反映"
  else
    warn "pi-web の再起動に失敗。設定を元に戻します"
    [[ -f "${PI_WEB_ENV}.bak" ]] && mv -f "${PI_WEB_ENV}.bak" "$PI_WEB_ENV"
    systemctl restart pi-web || true
    die "pi-web の設定を元に戻しました。journalctl -u pi-web を確認してください"
  fi
else
  ok "pi-web は停止中（次回起動時に反映される）"
fi

# Docker 版 Caddy は env_file の変更を反映するのにコンテナ再作成が要る
if [[ "$SYNCED_CADDY" -eq 0 ]] && systemctl is-enabled --quiet caddy 2>/dev/null && command -v docker >/dev/null 2>&1; then
  if ( cd ../duckdns && docker compose up -d >/dev/null 2>&1 ); then
    ok "Docker 版 Caddy を再作成して反映"
  else
    warn "Docker 版 Caddy の反映に失敗。手動で: cd ../duckdns && docker compose up -d"
  fi
fi

# --- 9) 初回の DuckDNS 更新 ---------------------------------------------------
echo "[4/4] DuckDNS を現在の IP に更新..."
if /usr/local/bin/pi-web-duckdns-update; then :; else
  warn "更新に失敗しました。トークンとアウトバウンド 443 を確認してください"
fi

cat <<MSG

完了。配布内容は ec2/.env の 1 ファイルが正である。

設定を変えたいとき:
  nano $(pwd)/.env   →   sudo ./install.sh
  （Caddy / Pi Web の設定を検証し、稼働中なら自動で再起動して反映する）

確認:
  sudo ./check.sh
MSG
