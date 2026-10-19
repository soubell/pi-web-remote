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

## 起動時の安全確認（重要）

`start-public.sh` は、Basic 認証を有効にした場合に **本当に認証が効いているか** を
起動直後に確認する。未認証で `https://<host>/` を叩いて:

判定は **2 段階**。

**(a) 未認証アクセスが「ngrok の認証」で弾かれるか**

| 応答 | 動作 |
| --- | --- |
| `401` | OK |
| `403` + `WWW-Authenticate` あり | OK（Basic 認証による拒否） |
| `403` + ヘッダなし | **中止**（Pi Web の Host 検証で弾かれている疑い。`PI_WEB_ALLOWED_HOSTS` を確認） |
| `200` / `30x` | **中止**（誰でも入れる状態なので公開しない） |
| 接続不能(`000`) / `5xx` | 再試行（`VERIFY_TIMEOUT` 秒まで） |
| その他 | **中止** |

**(b) 正しい認証情報なら Pi Web まで到達できるか**

`curl -u user:pass` で叩いて `200` / `30x` を確認する。(a) だけだと「403 の理由」を
区別できない（Pi Web も Host 検証で 403 を返すため）ので、両方通って初めて公開を継続する。

ngrok のバージョンによって Traffic Policy の書式が変わる可能性があるため、
「設定したつもりで認証が効いていない」状態を防ぐための Fail-closed にしてある。

ポリシーファイルは **Traffic Policy ドキュメント形式**（トップレベルが `on_http_request:`）で生成する。
`version: 3 / endpoints:` で始まる「エージェント設定ファイル」形式と混在させないこと。

```yaml
on_http_request:
  - actions:
      - type: basic-auth
        config:
          credentials:
            - "pi-user:パスワード"
```

- `NGROK_BASIC_PASSWORD` に 空白・`"`・`\`・`:` は使えない（`user:pass` 形式や curl 設定ファイルが壊れる）
- 認証情報は **コマンドライン引数に載せない**。所有者のみ読める一時ファイルを作り
  `curl --config` で渡す（`ps` に現れない）
- 待ち時間 (`READY_TIMEOUT` / `VERIFY_TIMEOUT`) は**ループ回数ではなく経過秒**で管理している。
  1 回の通信が遅くても、指定した秒数で打ち切られる

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
