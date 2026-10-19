#!/usr/bin/env bash
# 導通チェック（EC2 / Linux）。何が欠けているかを1コマンドで確認する
#   sudo ./check.sh
set -uo pipefail

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
ng()   { printf '  \033[31mNG\033[0m   %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
FAIL=0

ENV_FILE=/etc/pi-web/duckdns.env
DOMAIN=""
[[ -r "$ENV_FILE" ]] && DOMAIN="$(. "$ENV_FILE" && echo "${DUCKDNS_DOMAIN:-}")"

echo "== 1. ランタイム =="
NV="$(node --version 2>/dev/null | sed 's/^v//')" || NV=""
if [[ -n "$NV" ]] && [[ "$(printf '%s\n22.19.0\n' "$NV" | sort -V | head -1)" == "22.19.0" ]]; then
  ok "Node.js $NV"
else
  ng "Node.js が 22.19.0 未満または未導入 (${NV:-なし})"
fi
if docker version >/dev/null 2>&1; then ok "docker"; else ng "docker が使えない（グループ/起動状態を確認）"; fi
command -v caddy >/dev/null || ok "caddy はコンテナで動作（ホストには不要）"

echo
echo "== 2. Pi Web =="
if systemctl is-active --quiet pi-web; then ok "pi-web.service active"; else ng "pi-web.service が動いていない (journalctl -u pi-web)"; fi
if command -v ss >/dev/null; then
  BIND="$(ss -ltn 2>/dev/null | awk '$4 ~ /:30141$/ {print $4}' | head -1)"
  case "$BIND" in
    127.0.0.1:30141) ok "30141 は 127.0.0.1 のみで待ち受け" ;;
    "") ng "30141 が LISTEN していない" ;;
    *) ng "30141 が $BIND で待ち受け（0.0.0.0 は外部露出。要修正）" ;;
  esac
fi

echo
echo "== 3. DuckDNS =="
if [[ -z "$DOMAIN" ]]; then
  ng "$ENV_FILE が読めない / DUCKDNS_DOMAIN 未設定"
else
  CUR_IP="$(curl -sS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
  RESOLVED="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
  if [[ "$RESOLVED" == "$CUR_IP" ]]; then ok "$DOMAIN -> $CUR_IP"
  else ng "$DOMAIN -> ${RESOLVED:-未解決} / 実際の IP $CUR_IP（sudo /usr/local/bin/pi-web-duckdns-update を実行）"; fi
  systemctl is-active --quiet pi-web-duckdns.timer && ok "更新タイマー active" || warn "pi-web-duckdns.timer が inactive"
fi

echo
echo "== 4. Caddy / HTTPS =="
if systemctl is-active --quiet caddy-native 2>/dev/null; then
  ok "caddy-native.service active（ネイティブ / Docker なし）"
elif systemctl is-active --quiet caddy 2>/dev/null; then
  ok "caddy.service active（Docker 版）"
elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-web-caddy; then
  ok "caddy コンテナ稼働中（手動 compose）"
else
  ng "Caddy が動いていない（sudo systemctl status caddy-native / caddy）"
fi
if command -v ss >/dev/null; then
  ss -ltn 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}' && ok "443/tcp LISTEN" || ng "443/tcp が LISTEN していない"
fi
if [[ -n "$DOMAIN" ]]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN" 2>/dev/null)"
  case "$CODE" in
    401) ok "https://$DOMAIN -> 401（Basic 認証が効いている）" ;;
    000) ng "https://$DOMAIN に接続できない（SG / 証明書 / DNS）" ;;
    *)   warn "https://$DOMAIN -> $CODE（401 以外。ブラウザで確認）" ;;
  esac
  EXP="$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  [[ -n "$EXP" ]] && ok "証明書の有効期限: $EXP" || warn "証明書を取得できていない（docker compose logs caddy を確認）"
fi

echo
echo "== 5. 認証の通し（任意） =="
if [[ -n "$DOMAIN" ]] && [[ -t 0 ]]; then
  read -rp "  Basic 認証のユーザー名 [pi]: " BU; BU="${BU:-pi}"
  read -rsp "  Basic 認証のパスワード (空Enterでスキップ): " BP; echo
  if [[ -n "$BP" ]]; then
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "$BU:$BP" "https://$DOMAIN" 2>/dev/null)"
    [[ "$CODE" == "200" || "$CODE" == "302" ]] && ok "Basic 認証で通過 ($CODE) → Pi Web のログイン画面" \
      || ng "Basic 認証で通過しない ($CODE)"
  else
    warn "スキップ"
  fi
else
  warn "非対話環境なのでスキップ"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "結果: 問題なし"; else echo "結果: NG $FAIL 件"; fi
exit $(( FAIL > 0 ))
