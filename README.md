# Pi Web を外部から使う構成（テンプレート集）

[Pi Web](https://github.com/agegr/pi-web)（`pi coding agent` の Web UI）は、標準では
`127.0.0.1:30141` だけで待ち受け、認証はパスワード 1 個、通信は平文 HTTP。
このリポジトリは、それを**外から安全に使うための構成**をまとめたもの。

> ⚠️ **前提の共有**
> Pi Web はエージェントが `bash` を実行できる UI。つまり「公開した瞬間、URL と
> パスワードを知る人はあなたの権限で何でもできる」。どの構成でも **前段の認証
> （Basic 認証 / OAuth / VPN）を必ず重ねる**こと。

---

## 前提: 何が必要で、何が不要か

**pi（CLI）を別途インストールする必要はない。**
`@agegr/pi-web` は pi のパッケージ群（`@earendil-works/pi-coding-agent` など）を
依存として持っているので、`npx @agegr/pi-web` だけで UI とエージェントが揃う。
本リポジトリの `user-data.sh` も pi を入れていない（意図的に）。

| | 要否 | 補足 |
| --- | --- | --- |
| Node.js **22.19 以上** | 必須 | `@agegr/pi-web` の `engines` 指定 |
| pi CLI（`@earendil-works/pi-coding-agent`） | **不要** | pi-web の依存として入る。CLI も併用したい人だけ別途導入 |
| Pi Web 本体 | 不要 | `npx --yes @agegr/pi-web@latest` で毎回取得（`~/.npm` にキャッシュ） |
| Docker | Caddy 方式で必須 | `ngrok/` だけなら不要 |
| **モデルプロバイダの認証情報** | **必須（唯一の手動設定）** | 下記 |

### モデルの認証（初回に 1 回だけ）

どちらか。**どちらも `~/.pi/agent/auth.json` / 環境変数という pi 共通の仕組み**を使う。

1. **Web UI から**（`pi` の `/login` 相当）
   `https://<ドメイン>` にログイン → **Models** パネル → プロバイダを選んでログイン or API キー入力
2. **環境変数で渡す**（CI / ヘッドレス向け）
   `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` / `OPENROUTER_API_KEY` /
   `DEEPSEEK_API_KEY` / `XAI_API_KEY` / `GROQ_API_KEY` / `MISTRAL_API_KEY` など

   EC2 では `ec2/.env` に書けば `install.sh` が `/home/piweb/.config/pi-web/env` に
   コピーする（systemd の `EnvironmentFile` 経由で Pi Web が読む）。

### データの場所（実行ユーザーで決まる）

```
~/.pi/agent/                     既定。セッション・設定・auth.json
  └─ sessions/<cwd>/<ts>_<uuid>.jsonl
```

EC2 では実行ユーザーが `piweb` なので **`/home/piweb/.pi/agent`**。
既存の pi データを共有したい場合は `PI_CODING_AGENT_DIR` で場所を指定する
（`ec2/.env` に書けば配布される。パーミッションに注意）。

---

## まず 30 秒: どこで動かすか決める

| 環境 | ポート開放 | 推奨する方式 |
| --- | --- | --- |
| **EC2 / VPS** | SG で 443 を開けられる | **`ec2/`**（新規構築はこちら） |
| 自宅サーバ | 開けられる（グローバル IP 直持ち） | `duckdns/` |
| 自宅サーバ（CGNAT） | **開けられない** | `ngrok/` → 常用なら Cloudflare Tunnel / Tailscale |
| 一時的に見せたい | 不要 | `ngrok/` |

自宅回線が CGNAT かどうかは 30 秒で判定できる:

```bash
curl -s https://ifconfig.me; echo
```

ルータ管理画面の **WAN 側 IP** と比較し、**違えば CGNAT**（`100.64.*` / `10.*` /
`172.16-31.*` など）。日本の光回線（v6プラス / transix / NURO 等）は該当することが多い。
その場合 `duckdns/` は使えない（何をしてもインバウンドが届かない）。

---

## 方式の比較

| | `ec2/` | `duckdns/` | `ngrok/` |
| --- | --- | --- | --- |
| 想定環境 | EC2 / VPS | 自宅・VPS | どこでも（一時利用） |
| ポート開放 | SG で 443 | ルータで 443 | 不要 |
| CGNAT | ✅ 可 | ❌ 不可 | ✅ 可 |
| ドメイン | DuckDNS（無料） | DuckDNS（無料） | `*.ngrok-free.app` |
| HTTPS | Let's Encrypt（DNS-01） | Let's Encrypt（DNS-01） | ngrok |
| 認証 | Basic 認証 + Pi Web パスワード | 同左 | 同左 |
| IP 固定 | **不要**（起動時・5分ごとに DuckDNS 更新） | ルータ側で DDNS 更新 | — |
| 制限 | インスタンス課金 | 回線次第 | 20k req/月・1GB/月 |

**常用するなら `ec2/`**（設定は `.env` 1 枚、`install.sh` 一発）。
CGNAT 環境や自前ドメインがあるなら **Cloudflare Tunnel + Access** が最も安定するが、
本リポジトリには未収録。

---

## クイックスタート

### EC2（推奨）

```bash
# 1) インスタンス: Ubuntu 24.04 / t3.small 以上 / IAM ロールなし / IMDSv2 必須
#    ユーザーデータに ec2/user-data.sh を貼る（Docker・Node22・専用ユーザー piweb を作成）

git clone https://github.com/soubell/pi-web-remote.git
cd pi-web-remote/ec2
cp .env.example .env && nano .env      # 6 項目を埋める
sudo ./install.sh                      # 3 か所へ配布 + systemd 配置 + 初回 DuckDNS 更新

sudo systemctl enable --now pi-web caddy
```

`ec2/.env` に書くのはこれだけ:

```dotenv
DUCKDNS_DOMAIN=mypi.duckdns.org
DUCKDNS_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
ACME_EMAIL=you@example.com
BASIC_AUTH_USER=pi
BASIC_AUTH_PASSWORD=（32文字ランダム）
PI_WEB_PASSWORD=（別の32文字ランダム）
```

`install.sh` が配る先:

```
ec2/.env
   ├─► duckdns/.env.caddy              (600)  Caddy（証明書・Basic 認証・転送先）
   ├─► /etc/pi-web/duckdns.env         (600)  DuckDNS 更新（root 実行）
   └─► /home/piweb/.config/pi-web/env  (600)  Pi Web（piweb 所有）
```

- `PI_WEB_ALLOWED_HOSTS` は `DUCKDNS_DOMAIN` から自動生成
- Basic 認証のパスワードは**平文で書いてよい**（bcrypt に変換して配布）
- 変更したら `.env` を直して `sudo ./install.sh` を再実行（上書き配布）
- 書き込みなしで確認: `./install.sh --dry-run`

詳細と AWS 側の設定 → **[`ec2/README.md`](ec2/README.md)**

### 自宅サーバ / VPS

```bash
cd pi-web-remote/duckdns
./setup.sh                  # 対話: ドメイン / token / Basic 認証 → .env.caddy

PI_WEB_PASSWORD='...' PI_WEB_ALLOWED_HOSTS='mypi.duckdns.org' \
PI_WEB_IDLE_TIMEOUT_MS=0 PI_WEB_NO_OPEN=1 \
  npx @agegr/pi-web@latest -H 127.0.0.1 -p 30141 --no-open

docker compose up -d --build
```

詳細 → **[`duckdns/README.md`](duckdns/README.md)**

### 一時的に見せたいだけ

```bash
cd pi-web-remote/ngrok
PI_WEB_PASSWORD='...' NGROK_BASIC_PASSWORD='...' PUBLIC_HOST='xxxx.ngrok-free.app' ./start-public.sh
```

詳細 → **[`ngrok/README.md`](ngrok/README.md)**

---

## 構成図（EC2 / duckdns 共通）

```
[ブラウザ]
    │ HTTPS 443（SG / ルータで送信元制限）
    ▼
[Caddy (Docker, network_mode: host)]  Let's Encrypt 証明書（DNS-01 → 80 番不要）
    │             Basic 認証（第1層）
    │             flush_interval -1 / read_timeout 1h（SSE 対策）
    ▼
[Pi Web 127.0.0.1:30141]  PI_WEB_PASSWORD（第2層）
```

---

## 共通の前提と落とし穴

| 項目 | 内容 |
| --- | --- |
| Node.js | **22.19.0 以上** |
| 待ち受け | `-H 127.0.0.1`（外向きは Caddy だけ） |
| ホスト検証 | `PI_WEB_ALLOWED_HOSTS` に**完全一致**でドメイン（忘れると 403） |
| アイドル終了 | `PI_WEB_IDLE_TIMEOUT_MS=0`（既定 10 分で落ちる） |
| ストリーミング | SSE なのでプロキシでバッファリングしない（Caddy は `flush_interval -1`） |
| 認証 | Basic 認証と Pi Web パスワードは**別の値**（`openssl rand -base64 32`） |
| 専用ユーザー | エージェントはシェルを持つ。`~/.ssh` やクラウド資格情報を置かない |
| Docker | 必須ではない。Caddy を Docker で動かす場合は **`network_mode: host`**（Pi Web が 127.0.0.1 待ち受けのため）。EC2 はネイティブ Caddy で Docker 不要にできる（→ `ec2/README.md`） |
| 作業ディレクトリ | Pi Web が見せるのは「選択した作業ディレクトリ」配下のみ。EC2 では `/home/piweb/work` などを作る |

---

## ディレクトリ

```
ec2/        EC2 向け（.env 1枚 → install.sh が配布、EIP なしで DuckDNS 自動更新）
  ├── .env.example            設定の雛形（これだけ編集する）
  ├── install.sh              配布 + systemd 配置 + 初回更新（--dry-run あり）
  ├── user-data.sh            cloud-init（Docker / Node22 / piweb ユーザー / swap / IMDS 遮断）
  ├── update-duckdns.sh       パブリック IP → A レコード更新（root, 5分ごと）
  ├── pi-web.service          ExecStartPre で DuckDNS 更新 → Pi Web 起動
  ├── pi-web-duckdns.{service,timer}
  └── caddy.service           compose を systemd 管理

duckdns/    自宅サーバ / VPS 向け（Caddy + Basic 認証）
  ├── Caddyfile  Dockerfile  docker-compose.yml
  ├── setup.sh                対話で .env.caddy を生成
  └── .env.caddy.example

ngrok/      一時公開用
  ├── start-public.sh         Pi Web + ngrok + Basic 認証をまとめて起動
  └── README.md

agent/      汎用 systemd ユーザーサービス（EC2 では ec2/pi-web.service を使用）
```

---

## 秘密情報の扱い

- `.env` / `.env.*` / `*.pem` / `*.key` / `password` / `policy.yml` は `.gitignore` 済み
- コミットするのは **`.example` 雛形だけ**。実値は生成物
- 生成されるファイルはすべて `chmod 600`（`pi-web/env` は `piweb` 所有）
- 漏れた疑いがあれば: パスワード変更 → `sudo ./install.sh` 再実行 → 必要なら証明書削除

---

## 動いているか確認する

```bash
sudo ./ec2/check.sh
```

Node.js のバージョン / Pi Web の稼働と待ち受けアドレス / DuckDNS の A レコード /
443 の待ち受けと証明書の期限 / `https://<domain>` の 401（＋任意で Basic 認証の通し）
を点検し、欠けている項目を列挙する。
- EC2 では **IMDS を `piweb` から遮断**（`user-data.sh`）。エージェント経由で
  インスタンスメタデータを読まれないようにしている

---

## セキュリティ・チェックリスト

- [ ] 443 以外を開けていない（80 / 30141 は不要）
- [ ] 443 の送信元を自分の IP に制限（SG / ルータ / Caddy の `remote_ip`）
- [ ] Basic 認証と Pi Web パスワードが別の値・32 文字ランダム
- [ ] `PI_WEB_ALLOWED_HOSTS` が実際のドメインと完全一致
- [ ] `docker compose logs caddy` に 401 の連発が出ていないか時々見る
- [ ] Pi Web は専用ユーザーで実行、IAM ロールを付けない（EC2）
- [ ] データ（`/home/piweb/.pi` と `pi-web/env`）のバックアップ

---

## 参考

- Pi Web 本体: https://github.com/agegr/pi-web
- インタラクティブデモ（インストール不要）: https://agegr.github.io/pi-web/
- リモート公開の注意（本家 README の "Remote Access"）
- ngrok Traffic Policy: https://ngrok.com/docs/gateway/traffic-policy/examples/add-authentication
- Caddy DuckDNS プラグイン: https://github.com/caddy-dns/duckdns

## ライセンス

本リポジトリの設定例は MIT。Pi Web 本体のライセンスは[本家](https://github.com/agegr/pi-web)に従う。
