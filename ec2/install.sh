#!/usr/bin/env bash
# ec2/.env の 1 ファイルから、各サービスの環境変数を配布し、systemd ユニットを配置する
#
#   cd ec2
#   cp .env.example .env && nano .env     # 値を埋める
#   sudo ./install.sh
#
# 配布先:
#   ../duckdns/.env.caddy             (Caddy / docker compose の env_file)
#   /etc/pi-web/duckdns.env           (root が実行する DuckDNS 更新スクリプト)
#   /home/piweb/.config/pi-web/env    (Pi Web / systemd の EnvironmentFile)
set -euo pipefail
cd "$(dirname "$0")"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

die() { echo "エラー: $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }

# --- 0) 前提 ----------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
  [[ $EUID -eq 0 ]] || die "sudo で実行してください: sudo $0"
fi
ENV_FILE=".env"
[[ -f "$ENV_FILE" ]] || die "$(pwd)/.env がありません。cp .env.example .env して値を入れてください"

# .env を自前でパースする（source しない）
#   - CRLF（Windows での編集）に耐える
#   - 値に空白が入っていても「command not found」で落ちず、後段の検証で弾ける
#   - .env の中身がシェルとして実行される心配がない
while IFS= read -r _line || [[ -n "$_line" ]]; do
  _line="${_line%$'\r'}"
  [[ "$_line" =~ ^[[:space:]]*(#|$) ]] && continue
  _line="${_line#"${_line%%[![:space:]]*}"}"          # 先頭の空白を落とす
  _line="${_line#export }"
  [[ "$_line" == *=* ]] || continue
  _key="${_line%%=*}"
  _val="${_line#*=}"
  _key="${_key//[[:space:]]/}"
  [[ "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  if [[ "$_val" =~ ^\"(.*)\"$ ]] || [[ "$_val" =~ ^\'(.*)\'$ ]]; then
    _val="${BASH_REMATCH[1]}"
  else
    _val="${_val%"${_val##*[![:space:]]}"}"            # 末尾の空白だけ落とす
  fi
  printf -v "$_key" '%s' "$_val"
done < "$ENV_FILE"

: "${DUCKDNS_DOMAIN:?DUCKDNS_DOMAIN が空です}"
: "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN が空です}"
: "${BASIC_AUTH_PASSWORD:?BASIC_AUTH_PASSWORD が空です}"
: "${PI_WEB_PASSWORD:?PI_WEB_PASSWORD が空です}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-pi}"
# Caddyfile の `email` は引数が必須なので、空なら妥当な値を合成する（Unicode 不可）
ACME_EMAIL="${ACME_EMAIL:-acme@${DUCKDNS_DOMAIN}}"
[[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || die "ACME_EMAIL の形式が不正: $ACME_EMAIL"
PI_WEB_IDLE_TIMEOUT_MS="${PI_WEB_IDLE_TIMEOUT_MS:-0}"
# Caddy から Pi Web への転送先。ネイティブ/ホスト実行前提で 127.0.0.1
PI_WEB_UPSTREAM="${PI_WEB_UPSTREAM:-127.0.0.1:30141}"
SUB="${DUCKDNS_DOMAIN%.duckdns.org}"

[[ "$DUCKDNS_DOMAIN" == *".duckdns.org" ]] || die "DUCKDNS_DOMAIN は *.duckdns.org にしてください"
[[ ${#BASIC_AUTH_PASSWORD} -ge 12 ]] || die "BASIC_AUTH_PASSWORD は 12 文字以上にしてください"
[[ ${#PI_WEB_PASSWORD}   -ge 16 ]] || die "PI_WEB_PASSWORD は 16 文字以上にしてください"
[[ "$BASIC_AUTH_PASSWORD" != "$PI_WEB_PASSWORD" ]] || die "2 つのパスワードは別の値にしてください"
for _pw in "$BASIC_AUTH_PASSWORD" "$PI_WEB_PASSWORD"; do
  [[ "$_pw" =~ [[:space:]\"\'\$\\\#\;] ]] && \
    die "パスワードに空白・引用符・\$・#・; は使えません（systemd/Caddyfile が壊れます）。openssl rand -base64 32 を使ってください"
done
id -u piweb &>/dev/null || die "ユーザー piweb がありません（user-data.sh か手動で作成してください）"

# --- 1) bcrypt ハッシュを生成 ------------------------------------------------
#   Docker を入れない構成（ネイティブ Caddy）でも動くよう、3 経路を順に試す:
#     caddy(apt) → docker → htpasswd(apache2-utils)
echo "[1/4] Basic 認証のハッシュを生成..."
hash_password() {
  local pw="$1"
  if command -v caddy >/dev/null 2>&1; then
    printf '%s' "$pw" | caddy hash-password
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf '%s' "$pw" | docker run -i --rm caddy:2.11 caddy hash-password
  else
    if ! command -v htpasswd >/dev/null 2>&1; then
      echo "  htpasswd を導入（apache2-utils）..."
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq apache2-utils >/dev/null 2>&1 || true
    fi
    command -v htpasswd >/dev/null 2>&1 || die "bcrypt を作れません。caddy / docker / apache2-utils のいずれかを入れてください"
    # htpasswd -B は $2y$ を返すので $2a$ に寄せる（Caddy が確実に解釈できる形式）
    htpasswd -nbB -C 14 "${BASIC_AUTH_USER}" "$pw" | cut -d: -f2- | sed 's/^\$2y\$/$2a$/'
  fi
}

BASIC_AUTH_HASH="$(hash_password "$BASIC_AUTH_PASSWORD" | tr -d '\r')"
[[ "$BASIC_AUTH_HASH" == \$2[aby]\$* ]] || die "ハッシュ生成に失敗: $BASIC_AUTH_HASH"
ok "bcrypt 生成"

if [[ $DRY_RUN -eq 1 ]]; then
  cat <<EOF
[dry-run] 以下を書き込む予定（パスワードは伏字）:
  ../duckdns/.env.caddy
    DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
    DUCKDNS_API_TOKEN=***
    ACME_EMAIL=${ACME_EMAIL}
    BASIC_AUTH_USER=${BASIC_AUTH_USER}
    BASIC_AUTH_HASH=${BASIC_AUTH_HASH:0:7}***
    PI_WEB_UPSTREAM=${PI_WEB_UPSTREAM}
  /etc/pi-web/duckdns.env
    DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
    DUCKDNS_TOKEN=***
  /home/piweb/.config/pi-web/env
    PI_WEB_PASSWORD=***
    PI_WEB_ALLOWED_HOSTS=${DUCKDNS_DOMAIN}
    PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS}
    PI_WEB_NO_OPEN=1
EOF
  exit 0
fi

# --- 2) 配布 ----------------------------------------------------------------
echo "[2/4] 環境変数を配布..."

# (a) Caddy
umask 077
cat > ../duckdns/.env.caddy <<EOF
DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN}
DUCKDNS_API_TOKEN=${DUCKDNS_TOKEN}
ACME_EMAIL=${ACME_EMAIL}
BASIC_AUTH_USER=${BASIC_AUTH_USER}
BASIC_AUTH_HASH=${BASIC_AUTH_HASH}
PI_WEB_UPSTREAM=${PI_WEB_UPSTREAM}
EOF
# root が書くため、clone したユーザーが `docker compose` を直接叩けるよう所有権を戻す
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" ../duckdns/.env.caddy
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
install -d -o piweb -g piweb -m 700 /home/piweb/.config/pi-web
cat > /home/piweb/.config/pi-web/env <<EOF
PI_WEB_PASSWORD=${PI_WEB_PASSWORD}
PI_WEB_ALLOWED_HOSTS=${DUCKDNS_DOMAIN}
PI_WEB_IDLE_TIMEOUT_MS=${PI_WEB_IDLE_TIMEOUT_MS}
PI_WEB_NO_OPEN=1
EOF
# モデルプロバイダの API キー（.env に書かれているものだけ通す）
PROVIDER_KEYS=(
  ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY
  DEEPSEEK_API_KEY XAI_API_KEY GROQ_API_KEY MISTRAL_API_KEY
  MOONSHOT_API_KEY KIMI_API_KEY AI_GATEWAY_API_KEY
)
PASSED=()
for k in "${PROVIDER_KEYS[@]}"; do
  v="${!k:-}"
  [[ -n "$v" ]] && { printf '%s=%s\n' "$k" "$v" >> /home/piweb/.config/pi-web/env; PASSED+=("$k"); }
done
[[ -n "${PI_CODING_AGENT_DIR:-}" ]] && {
  printf 'PI_CODING_AGENT_DIR=%s\n' "$PI_CODING_AGENT_DIR" >> /home/piweb/.config/pi-web/env
  PASSED+=("PI_CODING_AGENT_DIR")
}
chown piweb:piweb /home/piweb/.config/pi-web/env
chmod 600 /home/piweb/.config/pi-web/env
ok "/home/piweb/.config/pi-web/env"
[[ ${#PASSED[@]} -gt 0 ]] && ok "プロバイダ設定を引き継ぎ: ${PASSED[*]}"

# ec2/.env 自体も 600 にしておく（平文パスワードが入っているため）
chmod 600 ./.env

# --- 3) systemd ユニット ----------------------------------------------------
echo "[3/4] systemd ユニットを配置..."
install -m 755 update-duckdns.sh /usr/local/bin/pi-web-duckdns-update
REPO_DIR="$(cd .. && pwd)"
UNITS=(pi-web-duckdns.service pi-web-duckdns.timer pi-web.service)
# Docker が無いなら Docker 版の caddy.service は配置しない（混乱と起動失敗の元）
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

# --- 4) 初回の DuckDNS 更新 --------------------------------------------------
echo "[4/4] DuckDNS を現在の IP に更新..."
if /usr/local/bin/pi-web-duckdns-update; then :; else
  echo "  ! 更新に失敗しました。トークンとアウトバウンド 443 を確認してください" >&2
fi

cat <<MSG

完了。配布内容は ec2/.env の 1 ファイルが正である。

次（Docker なし・推奨）:
  sudo ./install-caddy-native.sh        # 初回のみ。Caddy を導入して証明書を取得
  sudo systemctl enable --now pi-web
  sudo ./check.sh

次（Docker 版 Caddy を使う場合）:
  sudo systemctl enable --now pi-web caddy
  docker compose -f ../duckdns/docker-compose.yml logs -f caddy

確認:
  curl -sI https://${DUCKDNS_DOMAIN} | head -1     # -> HTTP/2 401

設定を変えたいとき:
  nano $(pwd)/.env   →   sudo ./install.sh   をもう一度実行（上書き配布）
MSG
