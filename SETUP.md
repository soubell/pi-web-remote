# これだけ: EC2 + DuckDNS で Pi Web を公開する

このリポジトリは **EC2 + DuckDNS** の1構成だけ使う前提の手順書。
（`duckdns/` は自宅サーバ用の予備。EC2 では使わない）

```
やること
  ① AWS でインスタンスを作る（Ubuntu 24.04 / t3.small / 443 を自分のIPだけに）
  ② SSH で入ってリポジトリを取る
  ③ .env に 5 項目書く
  ④ コマンド2つ叩く
  ⑤ ブラウザでログイン（Basic 認証 → Pi Web のパスワード）
  ⑥ Models パネルでプロバイダにログイン
```

---

## ① AWS でインスタンスを作る

| 項目 | 値 |
| --- | --- |
| AMI | Ubuntu Server 24.04 LTS |
| インスタンスタイプ | t3.small（2GB）以上 |
| ストレージ | 8GB で可（ネイティブ Caddy を使うので Docker 不要） |
| キーペア | 自分のもの |
| ネットワーク | パブリック IP 自動割り当て（**EIP は不要**） |
| IAM ロール | **付けない** |
| メタデータ | **IMDSv2 必須**（`HttpTokens=required`） |
| ユーザーデータ | `ec2/user-data.sh` の内容を貼る（Node22・専用ユーザー `piweb`・swap を作る。**Docker は入れない**） |

セキュリティグループ（**443 と 22 を自分の IP だけに**。80 と 30141 は開けない）:

| タイプ | ポート | 送信元 |
| --- | --- | --- |
| HTTPS | 443 | 自分の IP `/32` |
| SSH | 22 | 自分の IP `/32` |

---

## ② SSH で入ってリポジトリを取る

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<パブリックIP>
git clone https://github.com/soubell/pi-web-remote.git
cd pi-web-remote/ec2
```

---

## ③ `.env` に 5 項目書く

```bash
cp .env.example .env
nano .env
```

```dotenv
DUCKDNS_DOMAIN=mypi.duckdns.org          # ①で作った DuckDNS のドメイン
DUCKDNS_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx    # duckdns.org のトークン
ACME_EMAIL=you@example.com               # 空でも可（自動で acme@<domain> になる）
BASIC_AUTH_PASSWORD=（32文字ランダム）     # 1層目
PI_WEB_PASSWORD=（別の32文字ランダム）      # 2層目
```

```bash
openssl rand -base64 32    # パスワード生成（2回叩いて別々の値にする）
```

> モデルの API キーを使う場合はここに `ANTHROPIC_API_KEY=` なども書ける（後からでも可）。

---

## ④ コマンド2つ叩く

```bash
sudo ./install-caddy-native.sh  # Caddy 導入 + 設定配布 + systemd 配置 + 証明書取得
sudo systemctl enable --now pi-web
sudo ./check.sh                 # 問題がないか確認
```

> `install-caddy-native.sh` は Caddy の導入 → unit 配置 → `install.sh`（設定配布）→ 起動まで行う。
> **Docker は使わない。** これが標準構成（EC2 + ネイティブ Caddy + DuckDNS）。
>
> 設定の変更は今後 `sudo ./install.sh` だけでよい。検証 → 一括反映 → 再起動 → 事後確認まで行い、
> 途中で失敗したらファイル・権限・サービスをすべて元に戻す。

これで、URL は **`https://mypi.duckdns.org`**（DuckDNS）、証明書は Let's Encrypt、
入口は Basic 認証、その奥が Pi Web のログイン、という状態になる。

---

## ⑤ ブラウザでログイン

1. `https://mypi.duckdns.org`
2. **Basic 認証**（ユーザー `pi` / `BASIC_AUTH_PASSWORD`）
3. **Pi Web のログイン**（`PI_WEB_PASSWORD`）

---

## ⑥ Models パネルでプロバイダにログイン

Pi Web の **Models** パネル → 使うプロバイダを選んでログイン or API キー入力。
（`.env` に `ANTHROPIC_API_KEY=` 等を書いた場合は `sudo ./install.sh` 再実行で反映）

これで完了。作業ディレクトリは初期状態で `/home/piweb`。
専用の作業場所を作るなら:

```bash
sudo -u piweb mkdir -p /home/piweb/work
```

---

## 確認したいとき

```bash
sudo ./check.sh
```

Node.js のバージョン / Pi Web の稼働と待ち受け / DuckDNS の A レコード /
443 と証明書 / `https://<ドメイン>` が 401 を返すか、を一括で見る。

---

## 覚えておくこと

| 項目 | 内容 |
| --- | --- |
| **EIP なし** | stop/start で IP が変わるが、起動時と 5 分ごとに DuckDNS を自動更新（`pi-web-duckdns.timer`） |
| **Docker 不要（標準）** | Caddy はネイティブ（apt / systemd）。証明書は TLS-ALPN-01（443 のみ使用） |
| 設定の正 | `ec2/.env` 1枚。変えたら `sudo ./install.sh` を再実行 |
| ポート | 443 と 22 だけ。80 も 30141 も開けない |
| データ | `/home/piweb/.pi/agent`（セッション・認証情報） |
| パスワード | Basic 認証と Pi Web は**別の値**。どちらも 32 文字 |

詳しい注意点・トラブルシュート → [`ec2/README.md`](ec2/README.md)
