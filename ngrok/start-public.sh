#!/usr/bin/env bash
# Pi Web を ngrok 経由で「HTTPS + パスワード認証」で公開する起動スクリプト
#
#   PI_WEB_PASSWORD='...' PUBLIC_HOST='xxxx.ngrok-free.app' ./start-public.sh
#
# 前提:
#   - Node.js 22.19.0 以上
#   - ngrok アカウント + authtoken 設定済み (ngrok config add-authtoken ...)
#   - 自分の dev domain を取得済み (例: xxxx.ngrok-free.app)
set -euo pipefail

PORT="${PORT:-30141}"
PUBLIC_HOST="${PUBLIC_HOST:-}"          # 例: xxxx.ngrok-free.app (スキーム不要)
BASIC_USER="${BASIC_USER:-pi-user}"     # ngrok 側 Basic 認証のユーザー名 (任意の第2層)
PI_WEB_IDLE_TIMEOUT_MS="${PI_WEB_IDLE_TIMEOUT_MS:-0}"  # 0 = アイドルで落とさない

: "${PI_WEB_PASSWORD:?PI_WEB_PASSWORD を設定してください}"
: "${PUBLIC_HOST:?PUBLIC_HOST を設定してください (例: xxxx.ngrok-free.app)}"
command -v ngrok >/dev/null || { echo "ngrok が見つかりません: https://ngrok.com/download" >&2; exit 1; }

POLICY_FILE=""
PI_WEB_PID=""
NGROK_PID=""

cleanup() {
  echo -e "\n[stop] 終了処理中..."
  [[ -n "$NGROK_PID"     ]] && kill "$NGROK_PID"     2>/dev/null || true
  [[ -n "$PI_WEB_PID"    ]] && kill "$PI_WEB_PID"    2>/dev/null || true
  if command -v pi-web >/dev/null 2>&1; then pi-web stop --port "$PORT" >/dev/null 2>&1 || true; fi
  [[ -n "$POLICY_FILE"   ]] && rm -f "$POLICY_FILE"
}
trap cleanup EXIT INT TERM

# --- 1) Pi Web を 127.0.0.1 のみで起動（ngrok が localhost に繋ぎに行く） -------
echo "[1/3] Pi Web を起動中 (127.0.0.1:${PORT})..."
PI_WEB_PASSWORD="$PI_WEB_PASSWORD" \
PI_WEB_ALLOWED_HOSTS="$PUBLIC_HOST" \
PI_WEB_IDLE_TIMEOUT_MS="$PI_WEB_IDLE_TIMEOUT_MS" \
npx --yes @agegr/pi-web@latest --hostname 127.0.0.1 --port "$PORT" --no-open &
PI_WEB_PID=$!

echo -n "      待機中"
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null; then break; fi
  echo -n "."; sleep 1
done
echo " ok"
if ! kill -0 "$PI_WEB_PID" 2>/dev/null; then
  echo "Pi Web の起動に失敗しました" >&2; exit 1
fi

# --- 2) ngrok の Basic 認証ポリシーを一時ファイルに生成 ------------------------
NGROK_ARGS=(http "$PORT" --url "https://${PUBLIC_HOST}")

if [[ -n "${NGROK_BASIC_PASSWORD:-}" ]]; then
  POLICY_FILE="$(mktemp -t pi-web-tp.XXXXXX.yml)"
  chmod 600 "$POLICY_FILE"
  cat >"$POLICY_FILE" <<EOF
version: 3
endpoints:
  - name: pi-web
    url: https://${PUBLIC_HOST}
    upstream:
      url: ${PORT}
    traffic_policy:
      on_http_request:
        - actions:
            - type: basic-auth
              config:
                credentials:
                  - username: ${BASIC_USER}
                    password: ${NGROK_BASIC_PASSWORD}
EOF
  NGROK_ARGS+=(--traffic-policy-file "$POLICY_FILE")
  echo "[2/3] ngrok Basic 認証: 有効 (user=${BASIC_USER})"
else
  echo "[2/3] ngrok Basic 認証: 無効 (Pi Web のパスワードのみ)"
fi

# --- 3) ngrok トンネル開始 ----------------------------------------------------
echo "[3/3] ngrok トンネル開始..."
echo "      公開 URL: https://${PUBLIC_HOST}"
ngrok "${NGROK_ARGS[@]}" &
NGROK_PID=$!

wait "$NGROK_PID"
