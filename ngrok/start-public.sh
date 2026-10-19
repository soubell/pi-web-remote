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
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-30}"  # 公開 URL の検証待ち秒数

: "${PI_WEB_PASSWORD:?PI_WEB_PASSWORD を設定してください}"
: "${PUBLIC_HOST:?PUBLIC_HOST を設定してください (例: xxxx.ngrok-free.app)}"
command -v ngrok >/dev/null || { echo "ngrok が見つかりません: https://ngrok.com/download" >&2; exit 1; }

PUBLIC_HOST="${PUBLIC_HOST#https://}"; PUBLIC_HOST="${PUBLIC_HOST%%/*}"

POLICY_FILE=""
CURL_CFG=""
PI_WEB_PID=""
NGROK_PID=""
CLEANED=0

# EXIT / INT / TERM のすべてで、後始末をここに集約する（trap を上書きしない）
cleanup() {
  [[ "$CLEANED" -eq 1 ]] && return 0      # シグナルで複数回呼ばれても安全に
  CLEANED=1
  echo -e "\n[stop] 終了処理中..."
  [[ -n "$NGROK_PID"  ]] && kill "$NGROK_PID"  2>/dev/null || true
  [[ -n "$PI_WEB_PID" ]] && kill "$PI_WEB_PID" 2>/dev/null || true
  if command -v pi-web >/dev/null 2>&1; then pi-web stop --port "$PORT" >/dev/null 2>&1 || true; fi
  [[ -n "$POLICY_FILE" ]] && rm -f "$POLICY_FILE"
  [[ -n "$CURL_CFG"    ]] && rm -f "$CURL_CFG"
  return 0
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
# ループ回数ではなく「開始時刻からの経過秒」で打ち切る（1回の試行時間に左右されない）
READY_DEADLINE=$(( SECONDS + READY_TIMEOUT ))
while (( SECONDS < READY_DEADLINE )); do
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
  # YAML / curl 設定ファイルの両方に埋め込むので、形式を厳密に縛る
  [[ "$BASIC_USER" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || {
    echo "BASIC_USER の形式が不正です（英数字・.・_・- の 1〜32 文字）: $BASIC_USER" >&2; exit 1; }
  # "user:password" 形式で渡すため、区切り文字と curl 設定ファイルを壊す文字を禁止
  [[ "$NGROK_BASIC_PASSWORD" =~ [[:space:]\"\\\:] ]] && {
    echo "NGROK_BASIC_PASSWORD に 空白・\"・\\・: は使えません" >&2; exit 1; }

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

# --- 4) 認証が本当に効いているかを確認（fail-closed） -------------------------
#
#   2 段階で判定する。片方だけでは不十分:
#     (a) 未認証アクセスが「ngrok の認証」で弾かれること
#         ※ Pi Web 自身も Host 検証で 403 を返すため、403 だけでは区別できない。
#           WWW-Authenticate ヘッダの有無で「Basic 認証による拒否」かを判別する。
#     (b) 正しい認証情報を付ければ Pi Web まで到達すること（200/302）
probe() {
  # 引数は curl に渡す。標準出力: "<curl終了コード> <HTTPコード>"
  # curl は接続失敗時にも -w で 000 を出すので、終了コードと混ぜずに扱う
  local code rc=0
  if code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null)"; then rc=0; else rc=$?; fi
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  printf '%s %s' "$rc" "$code"
}

# 取得できた応答を「信頼してよいか」の判定。
#   curl が終了コード非 0 でも 3 桁のコードを返すことはあるが（転送の途中終了など）、
#   認証の有効性を判断する材料としては不十分なので、再試行扱いにする。
#   例外: 28（--max-time 超過）以外でコードが取れている場合も、ここでは安全側に倒す。
usable() {   # <rc> <code>
  [[ "$1" == "0" && "$2" =~ ^[0-9]{3}$ && "$2" != "000" ]]
}

probe_auth_header() {
  # 未認証で叩き、WWW-Authenticate ヘッダが付いていれば成功(=0)
  curl -s -o /dev/null -D - --max-time 5 "$@" 2>/dev/null \
    | tr -d '\r' | tr '[:upper:]' '[:lower:]' | grep -q '^www-authenticate:'
}

if [[ "$VERIFY_AUTH" -eq 1 ]]; then
  PUBLIC_URL="https://${PUBLIC_HOST}/"
  echo -n "[4/4] 認証の効きを確認"
  UNAUTH="000"; RC=1
  VERIFY_DEADLINE=$(( SECONDS + VERIFY_TIMEOUT ))
  while (( SECONDS < VERIFY_DEADLINE )); do
    if ! kill -0 "$NGROK_PID" 2>/dev/null; then
      echo; echo "ngrok が終了しました。" >&2; cat /tmp/pi-web-ngrok.log >&2; exit 1
    fi
    read -r RC UNAUTH <<<"$(probe "$PUBLIC_URL")"
    # curl が正常終了していない / 接続不能(000) / 5xx は「まだ準備できていない」として再試行
    if ! usable "$RC" "$UNAUTH"; then echo -n "."; sleep 2; continue; fi
    case "$UNAUTH" in 5??) echo -n "."; sleep 2; continue ;; esac
    break
  done
  echo

  if ! usable "$RC" "$UNAUTH"; then
    echo "      NG: ${VERIFY_TIMEOUT} 秒待っても有効な応答が得られませんでした (curl rc=${RC} / HTTP ${UNAUTH})。中止します。" >&2
    cat /tmp/pi-web-ngrok.log >&2
    exit 1
  fi

  case "$UNAUTH" in
    401)
      echo "      ok (未認証アクセスは 401 で遮断)"
      ;;
    403)
      if probe_auth_header "$PUBLIC_URL"; then
        echo "      ok (未認証アクセスは 403 + WWW-Authenticate で遮断)"
      else
        echo "      NG: 403 が返りましたが WWW-Authenticate がありません。" >&2
        echo "          ngrok の Basic 認証ではなく、Pi Web の Host 検証で弾かれている可能性があります。" >&2
        echo "          PI_WEB_ALLOWED_HOSTS='${PUBLIC_HOST}' を確認してください。公開を中止します。" >&2
        exit 1
      fi
      ;;
    200|30?)
      echo "      NG: 認証なしで ${UNAUTH} が返りました。Basic 認証が効いていません。公開を中止します。" >&2
      echo "          ngrok のバージョンで Traffic Policy の書式が異なる可能性があります。" >&2
      echo "          ngrok のログ: /tmp/pi-web-ngrok.log" >&2
      exit 1
      ;;
    *)
      echo "      NG: 想定外の応答 (${UNAUTH})。公開を中止します。" >&2
      cat /tmp/pi-web-ngrok.log >&2
      exit 1
      ;;
  esac

  # (b) 正しい認証情報で Pi Web まで到達できるか（ここまで通って初めて「公開してよい」）
  # 認証情報は argv に載せない（ps で見えないように、0600 の一時設定ファイルを -K で渡す）
  CURL_CFG="$(mktemp -t pi-web-curl.XXXXXX)"
  chmod 600 "$CURL_CFG"
  printf 'user = "%s:%s"\n' "$BASIC_USER" "$NGROK_BASIC_PASSWORD" > "$CURL_CFG"

  echo -n "      認証ありで疎通確認"
  AUTH="000"
  VERIFY_DEADLINE=$(( SECONDS + VERIFY_TIMEOUT ))
  while (( SECONDS < VERIFY_DEADLINE )); do
    read -r RC AUTH <<<"$(probe --config "$CURL_CFG" "$PUBLIC_URL")"
    if ! usable "$RC" "$AUTH"; then echo -n "."; sleep 2; continue; fi
    case "$AUTH" in 5??) echo -n "."; sleep 2; continue ;; esac
    break
  done
  rm -f "$CURL_CFG"; CURL_CFG=""
  echo
  case "$AUTH" in
    200|30?|307|308)
      echo "      ok (認証ありで ${AUTH} → Pi Web に到達)"
      ;;
    401)
      echo "      NG: 認証ありでも 401。ユーザー名/パスワードを確認してください。中止します。" >&2
      exit 1
      ;;
    403)
      echo "      NG: 認証ありで 403。Pi Web の Host 検証の可能性があります。" >&2
      echo "          PI_WEB_ALLOWED_HOSTS='${PUBLIC_HOST}' を確認してください。中止します。" >&2
      exit 1
      ;;
    *)
      echo "      NG: 想定外の応答 (${AUTH})。中止します。" >&2
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
