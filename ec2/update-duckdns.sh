#!/usr/bin/env bash
# DuckDNS の A レコードを、このインスタンスの現在のパブリック IP に更新する
#   - Pi Web の起動時（systemd ExecStartPre）と、5分ごとのタイマーから呼ばれる
#   - 変わっていなければスキップする（DuckDNS への無駄なリクエストを避ける）
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/pi-web/duckdns.env}"

# 設定ファイルは「シェルとして実行」せず、データとして読む
# （値を取り違えても任意コード実行にならない）
read_env() {
  local key="$1" line
  [[ -r "$ENV_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == "$key="* ]] || continue
    printf '%s' "${line#*=}"
    return 0
  done < "$ENV_FILE"
}

DUCKDNS_DOMAIN="$(read_env DUCKDNS_DOMAIN)"
DUCKDNS_TOKEN="$(read_env DUCKDNS_TOKEN)"

: "${DUCKDNS_DOMAIN:?DUCKDNS_DOMAIN が未設定（$ENV_FILE を確認）}"
: "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN が未設定（$ENV_FILE を確認）}"
# 念のため再検証（生成元以外からの書き換えに備える）
[[ "$DUCKDNS_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.duckdns\.org$ ]] || {
  echo "[duckdns] DUCKDNS_DOMAIN の形式が不正: $DUCKDNS_DOMAIN" >&2; exit 1; }
[[ "$DUCKDNS_TOKEN" =~ ^[A-Za-z0-9-]{8,64}$ ]] || {
  echo "[duckdns] DUCKDNS_TOKEN の形式が不正" >&2; exit 1; }

# DuckDNS API はサブドメイン部分だけを受け付ける
SUB="${DUCKDNS_DOMAIN%.duckdns.org}"

log() { echo "[duckdns] $*" >&2; }

# --- 1) パブリック IP を取得（IMDSv2 優先、だめなら外部サービス） --------------
IP=""
MTOKEN="$(curl -sS -X PUT --max-time 2 \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
  http://169.254.169.254/latest/api/token 2>/dev/null || true)"
if [[ -n "$MTOKEN" ]]; then
  CAND="$(curl -sS --max-time 2 -H "X-aws-ec2-metadata-token: $MTOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  # EC2 以外では "Resource not found..." のような文字列が返るので必ず検証する
  [[ "$CAND" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && IP="$CAND"
fi
if [[ -z "$IP" ]]; then
  IP="$(curl -sS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
fi
if [[ ! "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  log "パブリック IP を取得できませんでした（IP='$IP'）"
  exit 1
fi

# --- 2) 現在のレコードと比較 ---------------------------------------------------
CUR="$(getent hosts "$DUCKDNS_DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
if [[ "$CUR" == "$IP" ]]; then
  log "変更なし（$DUCKDNS_DOMAIN -> $IP）"
  exit 0
fi

# --- 3) 更新 ------------------------------------------------------------------
RESP="$(curl -sS --max-time 10 \
  "https://www.duckdns.org/update?domains=${SUB}&token=${DUCKDNS_TOKEN}&ip=${IP}" || true)"
if [[ "$RESP" == "OK" ]]; then
  log "更新しました（${CUR:-未解決} -> $IP）"
else
  log "更新に失敗しました: 応答='$RESP'"
  exit 1
fi
