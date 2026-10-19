# 方式C: ngrok + Basic 認証

一時的に外から見たいとき用。**ポート開放不要・CGNAT でも動く**。
`start-public.sh` が Pi Web と ngrok をまとめて起動する。

```
[ブラウザ] --HTTPS--> [ngrok エッジ] --トンネル--> [ngrok agent] --> [Pi Web 127.0.0.1:30141]
                        ↑ Basic 認証 / ログ
```

## 準備（初回だけ）

```bash
node --version                 # 22.19.0 以上
brew install ngrok             # または https://ngrok.com/download
ngrok config add-authtoken <YOUR_TOKEN>
```

ダッシュボード（Domains）で **dev domain** を1つ確保する。無料プランでも
`xxxx.ngrok-free.app` が1つもらえ、再起動しても URL は変わらない。

無料プランの上限（2026年時点）: 月 20,000 HTTP リクエスト / 1 GB 転送 / 同時 3 エンドポイント。
Pi Web の SSE は接続を保持するので、**転送量（1 GB）** に注意。

## 起動

```bash
PI_WEB_PASSWORD='(32文字ランダムA)' \
NGROK_BASIC_PASSWORD='(32文字ランダムB)' \
PUBLIC_HOST='xxxx.ngrok-free.app' \
./start-public.sh
```

停止は `Ctrl-C`（Pi Web と ngrok の両方が落ちる）。

| 変数 | 既定 | 説明 |
| --- | --- | --- |
| `PI_WEB_PASSWORD` | 必須 | Pi Web のログインパスワード |
| `NGROK_BASIC_PASSWORD` | 未設定＝無効 | ngrok 側 Basic 認証（設定を強く推奨） |
| `PUBLIC_HOST` | 必須 | `xxxx.ngrok-free.app`（スキームなし） |
| `BASIC_USER` | `pi-user` | Basic 認証のユーザー名 |
| `PORT` | `30141` | Pi Web のローカルポート |
| `PI_WEB_IDLE_TIMEOUT_MS` | `0` | アイドル自動終了を無効化 |

## ハマりどころ

| 症状 | 原因 / 対処 |
| --- | --- |
| 初回に「You are about to visit…」 | 無料プランの警告ページ。「Visit Site」を1回押す（以後7日間 Cookie でスキップ）。API 呼び出しは影響なし |
| `403 Invalid host` | `PI_WEB_ALLOWED_HOSTS` に dev domain を完全一致で追加。だめなら `--host-header=rewrite` |
| 放置するとログイン画面に戻る | `PI_WEB_IDLE_TIMEOUT_MS=0` |
| `ERR_NGROK_8012` | Pi Web が起動していない / ポート違い |

## 注意

- 無料プランの警告ページは消せない（消すなら有料プラン）
- URL とパスワードを知る人は、あなたの権限でコマンドを実行できる
- 常用するなら `../duckdns/` か Cloudflare Tunnel + Access に移行する
