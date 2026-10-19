#!/usr/bin/env bash
# Pi Web を ngrok 経由で「HTTPS + パスワード認証」で公開する起動スクリプト
#
#   PI_WEB_PASSWORD='...' NGROK_BASIC_PASSWORD='...' PUBLIC_HOST='xxxx.ngrok-free.app' ./start-public.sh
#
# 前提:
#   - Node.js 22.19.0 以上
#   - ngrok アカウント + authtoken 設定済み (ngrok config add-authtoken ...)
#   - 自分の dev domain を取得済み (例: xxxx.ngrok-free.app)
set -euo pipefail

PORT="${PORT:-30141}"
PUBLIC_HOST="${PUBLIC_HOST:-}"          # 例: xxxx.ngrok-free.app (スキーム不要)
BASIC_USER="${BASIC_USER:-pi-user}"     # ngrok 側 Basic 認証のユーザー名
PI_WEB_IDLE_TIMEOUT_MS="${PI_WEB_IDLE_TIMEOUT_MS:-0}"
READY_TIMEOUT="${READY_TIMEOUT:-60}"    # Pi Web の起動待ち秒数
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-30}"  # Basic 認証の効きを確認するまでの秒数

: "${PI_WEB_PASSWORD:?PI_WEB_PASSWORD を設定してください}"
: "${PUBLIC_HOST:?PUBLIC_HOST を設定してください (例: xxxx.ngrok-free.app)}"
command -v ngrok >/dev/null || { echo "ngrok が見つかりません: https://ngrok.com/download" >&2; exit 1; }

PUBLIC_HOST="${PUBLIC_HOST#https://}"; PUBLIC_HOST="${PUBLIC_HOST%%/*}"

POLICY_FILE=""
PI_WEB_PID=""
NGROK_PID=""

cleanup() {
  echo -e "\n[stop] 終了処理中..."
  [[ -n "$NGROK_PID"  ]] && kill "$NGROK_PID"  2>/dev/null || true
  [[ -n "$PI_WEB_PID" ]] && kill "$PI_WEB_PID" 2>/dev/null || true
  if command -v pi-web >/dev/null 2>&1; then pi-web stop --port "$PORT" >/dev/null 2>&1 || true; fi
  [[ -n "$POLICY_FILE" ]] && rm -f "$POLICY_FILE"
}
trap cleanup EXIT INT TERM

# --- 1) Pi Web を 127.0.0.1 のみで起動 ----------------------------------------
echo "[1/4] Pi Web を起動中 (127.0.0.1:${PORT})..."
PI_WEB_PASSWORD="$PI_WEB_PASSWORD" \
PI_WEB_ALLOWED_HOSTS="$PUBLIC_HOST" \
PI_WEB_IDLE_TIMEOUT_MS="$PI_WEB_IDLE_TIMEOUT_MS" \
npx --yes @agegr/pi-web@latest --hostname 127.0.0.1 --port "$PORT" --no-open &
PI_WEB_PID=$!

echo -n "      起動待ち"
READY=0
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$PI_WEB_PID" 2>/dev/null; then
    echo; echo "Pi Web のプロセスが終了しました（ログを確認してください）" >&2; exit 1
  fi
  echo -n "."; sleep 1
done
echo
if [[ "$READY" -ne 1 ]]; then
  echo "Pi Web が ${READY_TIMEOUT} 秒以内に応答しませんでした。中止します。" >&2
  echo "（ポート ${PORT} が既に使われていないか、ログを確認してください）" >&2
  exit 1
fi
echo "      ok (HTTP 応答を確認)"

# --- 2) ngrok の Basic 認証ポリシー -------------------------------------------
NGROK_ARGS=(http "$PORT" --url "https://${PUBLIC_HOST}")
VERIFY_AUTH=0

if [[ -n "${NGROK_BASIC_PASSWORD:-}" ]]; then
  # "user:password" 形式で渡すため、区切り文字は使わせない
  [[ "$NGROK_BASIC_PASSWORD" == *:* ]] && { echo "NGROK_BASIC_PASSWORD に ':' は使えません" >&2; exit 1; }

  # --traffic-policy-file は「Traffic Policy ドキュメント」を取る。
  # エンドポイント定義（version: 3 / endpoints: ...）と混ぜないこと。
  POLICY_FILE="$(mktemp -t pi-web-tp.XXXXXX.yml)"
  chmod 600 "$POLICY_FILE"
  cat >"$POLICY_FILE" <<EOF
on_http_request:
  - actions:
      - type: basic-auth
        config:
          credentials:
            - "${BASIC_USER}:${NGROK_BASIC_PASSWORD}"
EOF
  NGROK_ARGS+=(--traffic-policy-file "$POLICY_FILE")
  VERIFY_AUTH=1
  echo "[2/4] ngrok Basic 認証: 有効 (user=${BASIC_USER})"
else
  echo "[2/4] ngrok Basic 認証: 無効（Pi Web のパスワードのみで公開されます）"
fi

# --- 3) ngrok トンネル開始 ----------------------------------------------------
echo "[3/4] ngrok トンネル開始..."
echo "      公開 URL: https://${PUBLIC_HOST}"
ngrok "${NGROK_ARGS[@]}" >/tmp/pi-web-ngrok.log 2>&1 &
NGROK_PID=$!

# --- 4) 認証が本当に効いているかを確認（効いていなければ中止） -----------------
if [[ "$VERIFY_AUTH" -eq 1 ]]; then
  echo -n "[4/4] Basic 認証の効きを確認"
  CODE="000"
  for _ in $(seq 1 "$VERIFY_TIMEOUT"); do
    kill -0 "$NGROK_PID" 2>/dev/null || { echo; echo "ngrok が終了しました。" >&2; cat /tmp/pi-web-ngrok.log >&2; exit 1; }
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://${PUBLIC_HOST}/" 2>/dev/null || echo 000)"
    [[ "$CODE" != "000" ]] && break
    echo -n "."; sleep 2
  done
  echo
  case "$CODE" in
    401|403)
      echo "      ok (未認証アクセスは ${CODE} で遮断)"
      ;;
    200)
      # 認証がかかっていない = 誰でも入れる状態。公開を続けない
      echo "      NG: 認証なしで 200 が返りました。Basic 認証が効いていません。" >&2
      echo "      （ngrok のバージョンで Traffic Policy の書式が異なる可能性があります）" >&2
      echo "      ngrok のログ: /tmp/pi-web-ngrok.log" >&2
      exit 1
      ;;
    *)
      echo "      NG: 想定外の応答 (${CODE})。公開を中止します。" >&2
      cat /tmp/pi-web-ngrok.log >&2
      exit 1
      ;;
  esac
else
  echo "[4/4] Basic 認証は無効のためスキップ（Pi Web のパスワードのみ）"
fi

echo
echo "公開中: https://${PUBLIC_HOST}"
echo "停止: Ctrl-C"

wait "$NGROK_PID"
