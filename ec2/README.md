# EC2 で動かす（Elastic IP なし）

`../duckdns/` の構成（Caddy + Basic 認証 + Pi Web）を EC2 上に置く手順。
**EIP は使わない。** stop/start でパブリック IP が変わっても、**Pi Web の起動時と 5 分ごと**に
DuckDNS を更新して追従させる。

```
[インターネット]
      │ 443（SG で送信元 IP を制限）
      ▼
[EC2]  パブリック IP は可変 → DuckDNS の A レコードを自動更新
   ├ Caddy (Docker)  … Let's Encrypt / Basic 認証
   └ Pi Web (systemd, 専用ユーザー piweb, 127.0.0.1:30141)
        └ ExecStartPre で DuckDNS 更新（+ 5分ごとの timer）
```

---

## 0. 先に決めること

| 項目 | 推奨 | 理由 |
| --- | --- | --- |
| AMI | **Ubuntu 24.04 LTS** | docker / NodeSource の手順が素直 |
| インスタンス | **t3.small (2GB)** 以上 | Caddy の自前ビルド（xcaddy）が 1GB だと OOM しがち。t3.micro なら swap 必須（`user-data.sh` が 2GB 作成） |
| Elastic IP | **使わない** | 代わりに DuckDNS 自動更新（このページの主題） |
| EBS | **20GB gp3**（ネイティブ Caddy なら 8GB でも可） | Ubuntu 2.5 + Node/npm 1.5 + Docker 3 + swap 2 + 余裕 |
| IAM ロール | **付けない** | エージェントが bash を実行できるため |

**EIP なしのデメリット**（理解した上で選ぶ）:

- stop/start のたびにパブリック IP が変わる → DuckDNS 更新が数秒〜数十秒遅れる間は繋がらない
- DuckDNS の TTL（60 秒）＋クライアントのDNSキャッシュで、切り替え直後は最大1〜2分ほど不安定
- **reboot（OS 再起動）では IP は変わらない**。変わるのは stop/start と、AWS 側のメンテナンス時

> 逆に言えば、**動かしっぱなしなら IP はほとんど変わらない**。自動更新はその保険。

---

## 1. セキュリティグループ

**443 は自分の IP だけ**。22 も同様。80 と 30141 は開けない。

| タイプ | ポート | 送信元 | 用途 |
| --- | --- | --- | --- |
| HTTPS | 443 | 自分の IP `/32` | Pi Web |
| HTTPS (UDP) | 443 | 同上 | HTTP/3（任意） |
| SSH | 22 | 自分の IP | 管理 |

```bash
SG=sg-xxxxxxxx
MYIP=$(curl -s https://ifconfig.me)/32

aws ec2 authorize-security-group-ingress --group-id $SG --ip-permissions \
  "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$MYIP,Description=\"pi-web\"}]" \
  "IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$MYIP,Description=\"pi-web-h3\"}]" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MYIP,Description=\"ssh\"}]"

# 既定の 0.0.0.0/0 ルールが残っていれば閉じる
aws ec2 revoke-security-group-ingress --group-id $SG \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]'
```

> 動的に IP が変わる回線から使うなら、443 を全世界に開けた上で Caddyfile の IP 制限ではなく
> Basic 認証の強度で守る（32 文字ランダム）。厳密にやるなら SSM Session Manager 経由にする。

---

## 2. 起動と初期設定

インスタンス起動時、**「高度な詳細 > ユーザーデータ」に `user-data.sh` を貼る**。
（Docker / Node.js 22 / 専用ユーザー `piweb` / swap / IMDS 遮断 まで入る）

手動なら:

```bash
curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker ubuntu   # 再ログイン
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs
sudo useradd -m -s /bin/bash piweb
sudo install -d -o piweb -g piweb /home/piweb/.config/pi-web
```

---

## 3. デプロイ（設定は `.env` 1枚だけ）

```bash
git clone https://github.com/soubell/pi-web-remote.git
cd pi-web-remote/ec2

cp .env.example .env
nano .env          # ↓ の6行を埋めるだけ

sudo ./install.sh  # 3か所に配布 + systemd 配置 + 初回 DuckDNS 更新まで一括
```

### `ec2/.env` に書くもの

```dotenv
DUCKDNS_DOMAIN=mypi.duckdns.org
DUCKDNS_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
ACME_EMAIL=you@example.com
BASIC_AUTH_USER=pi
BASIC_AUTH_PASSWORD=（32文字ランダム）
PI_WEB_PASSWORD=（別の32文字ランダム）
```

| キー | 説明 |
| --- | --- |
| `DUCKDNS_DOMAIN` | DuckDNS で作ったドメイン。`PI_WEB_ALLOWED_HOSTS` にも自動で入る |
| `DUCKDNS_TOKEN` | duckdns.org のトークン（A レコード更新と DNS-01 の両方に使う） |
| `ACME_EMAIL` | Let's Encrypt の登録メール（空でも可） |
| `BASIC_AUTH_USER` | Caddy の Basic 認証ユーザー（省略時 `pi`） |
| `BASIC_AUTH_PASSWORD` | **平文で書く**。install.sh が bcrypt に変換して配る |
| `PI_WEB_PASSWORD` | Pi Web のログインパスワード。Basic 認証とは別の値にする |

```bash
# パスワードを作る
openssl rand -base64 32
```

### `install.sh` が配る先

```
ec2/.env
   ├─► duckdns/.env.caddy              (600) Caddy / docker compose の env_file
   ├─► /etc/pi-web/duckdns.env         (600) DuckDNS 更新（root 実行）
   └─► /home/piweb/.config/pi-web/env  (600, piweb 所有) Pi Web / systemd
```

`ec2/.env` 自体も `chmod 600` にし、Git 管理外（`.gitignore` 済み）。
**値を変えたいときは `.env` を直して `sudo ./install.sh` を再実行**するだけでよい。

配布だけ確認したいとき（書き込まない）:

```bash
./install.sh --dry-run     # 伏字で内容を表示
```

### 起動

```bash
sudo systemctl enable --now pi-web

# Caddy はどちらか一方だけ
sudo ./install-caddy-native.sh        # 推奨: ネイティブ（Docker なし）
# sudo systemctl enable --now caddy   # Docker 版を使う場合のみ

# 何が欠けているかを一発で確認
sudo ./check.sh
```

`check.sh` は Node.js のバージョン / pi-web サービスの稼働 / **30141 が 127.0.0.1 のみか** /
DuckDNS の A レコードが現在の IP か / 443 の待ち受け / 証明書の期限 /
`https://<domain>` が 401 を返すか（＋任意で Basic 認証の通し）を点検する。

### モデルの設定（初回だけ・これが最後の手動設定）

Pi Web / pi 本体は依存として入るので、**pi CLI を別途インストールする必要はない**。
必要なのは「どのモデルを、どの認証で使うか」だけ。

**方法 A: ブラウザから（推奨・ログイン型プロバイダ向け）**

`https://<ドメイン>` → Basic 認証 → Pi Web のパスワード → **Models** パネル →
プロバイダを選んでログイン（ChatGPT サブスク、Claude、GitHub Copilot など）or API キー入力。
認証情報は `/home/piweb/.pi/agent/auth.json` に保存される（`chmod 600`、`piweb` 所有）。

**方法 B: `.env` に API キーを書く（ヘッドレス・再構築が楽）**

```dotenv
# ec2/.env
ANTHROPIC_API_KEY=sk-ant-...
OPENROUTER_API_KEY=sk-or-...
```

`sudo ./install.sh` を再実行すると `/home/piweb/.config/pi-web/env` にコピーされ、
systemd の `EnvironmentFile` 経由で Pi Web が読む。対応する変数名は
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` / `OPENROUTER_API_KEY` /
`DEEPSEEK_API_KEY` / `XAI_API_KEY` / `GROQ_API_KEY` / `MISTRAL_API_KEY` /
`MOONSHOT_API_KEY` / `KIMI_API_KEY` / `AI_GATEWAY_API_KEY`。

> 有効になったかは、UI のモデルピッカーにモデルが並ぶかで分かる。
> 認証が無いと「モデルが 1 つも選べない」状態になる。

### Docker を使わない（容量を抑える）

Docker が必要な理由は **Caddy に DuckDNS プラグインを組み込むため**だけ。
443 が外から届く EC2 では、**TLS-ALPN-01 で証明書が取れるのでプラグイン自体が不要**
＝素の Caddy で済む。

```bash
sudo ./install-caddy-native.sh   # Caddy 導入 → 設定配布(install.sh) → 起動まで一括
sudo systemctl enable --now pi-web
```

| | Docker 版（DNS-01） | ネイティブ版（TLS-ALPN-01） |
| --- | --- | --- |
| 証明書の検証経路 | DuckDNS の TXT レコード | 443 の TLS ハンドシェイク |
| 追加ディスク | **約 2〜3GB**（builder イメージ + Go ビルドキャッシュ） | **約 20MB**（.deb 17MB） |
| 必要なインバウンド | **443**（サービス提供用。CGNAT では公開自体が不可） | **443**（同じ。検証にも流用するので追加ゼロ） |
| 80 番 | 不要 | 不要 |
| 向く環境 | オリジンがトンネルの裏（Cloudflare Tunnel 等）、VPN/LAN 内公開、ワイルドカード証明書 | **EC2 / VPS（公開 443 で配信する構成）** |

> どちらも **443 がインターネットから到達できることが前提**（サービスを公開する以上そうなる）。
> DNS-01 が効くのは「443 を外に開けずに証明書だけ欲しい」ケース、つまり
> トンネル/VPN 経由で配信する場合や `*.example.com` が必要な場合であって、
> **CGNAT を解決する手段ではない**（CGNAT なら経路が無いので公開できない）。

Docker 版に戻すには:

```bash
sudo systemctl disable --now caddy-native
cd ../duckdns && docker compose up -d --build
```

> ネイティブ版を使うなら `user-data.sh` の Docker 導入部分は不要になる
> （`apt-get install -y docker-ce ...` の行を消してよい）。Node.js と Caddy だけで動く。

### Caddy の実行権限と設定の置き場所

ネイティブ版の Caddy は **専用ユーザー `caddy`** で動く（root ではない）。
443 へのバインドだけを capability で許可している。

| パス | 所有者 / 権限 | 用途 |
| --- | --- | --- |
| `/etc/pi-web/caddy.env` | `root:caddy` 0640 | `duckdns/.env.caddy` の写し（`caddy` が読めるように） |
| `/etc/pi-web/Caddyfile` | root 0644 | `duckdns/Caddyfile.native` の写し |
| `/var/lib/caddy` | `caddy:caddy` | 証明書・ACME アカウント（`XDG_DATA_HOME`） |
| `/var/log/caddy` | `caddy:caddy` | アクセスログ |

`duckdns/.env.caddy` は 600（clone したユーザー所有）のまま。Caddy は直接読まず、
`install-caddy-native.sh` が 0640 の写しを作る。

> **設定変更は `sudo ./install.sh` だけでよい。** 次の順で安全に反映される:
>
> 1. 新しい設定を**一時ファイル**に書く
> 2. `caddy validate` で検証（**失敗したら何も置き換えない**＝稼働中の設定はそのまま）
> 3. 検証が通ったら `mv` で置換（atomic）
> 4. `caddy-native` を再起動。**失敗したら元の設定に戻して**再起動を試みる
> 5. `pi-web` も再起動して `EnvironmentFile` を読み直させる
>
> `EnvironmentFile` はプロセス起動時にしか読まれないため、ファイルを書き換えただけでは
> 稼働中の Pi Web に反映されない（パスワード変更が効かない等）。
> `Caddyfile.native` は `admin off` なので `caddy reload`（Admin API）は使えない。
>
> Docker 版 Caddy を使っている場合、`env_file` の変更はコンテナ再作成が必要。
> `install.sh` は `docker compose up -d` まで試みる（失敗時は手動実行を案内）。

### 作業ディレクトリ（エージェントに触らせる場所）

Pi Web は「選択した作業ディレクトリ」配下しかファイルブラウザで見せない。
`pi-web.service` の `WorkingDirectory=/home/piweb` なので、初期状態ではホームが対象。

```bash
sudo -u piweb mkdir -p /home/piweb/work && sudo -u piweb git -C /home/piweb/work init
```

UI から `work` を選択して使う。特定のリポジトリを対象にしたいなら clone してから選ぶ。
**認証情報（`~/.ssh`, `~/.aws`）は `piweb` のホームに置かない**こと。

### データの場所

```
/home/piweb/.pi/agent/         セッション・設定・auth.json（実行ユーザー piweb）
/home/piweb/.config/pi-web/env 環境変数（install.sh が生成）
```

既存の pi データを共有したい場合のみ `ec2/.env` に `PI_CODING_AGENT_DIR=/home/ubuntu/.pi/agent`
を書く（読み書き権限に注意。`piweb` から読めないと失敗する）。


> `PI_WEB_PASSWORD` を後から確認したい場合は
> `sudo cat /home/piweb/.config/pi-web/env`（root のみ）。
>
> `duckdns/setup.sh` は **EC2 では使わない**（`install.sh` が `.env.caddy` も作るため）。

---

## 4. DuckDNS 自動更新の中身

`update-duckdns.sh` の流れ:

1. **パブリック IP を取得** — IMDSv2（`169.254.169.254`）→ 失敗時は `https://checkip.amazonaws.com`
2. **現在の A レコードと比較**（`getent hosts`）— 同じなら何もしない（無駄な更新を避ける）
3. `https://www.duckdns.org/update?domains=<sub>&token=<token>&ip=<ip>` を叩いて `OK` を確認

**呼ばれるタイミング**

| 契機 | 仕組み |
| --- | --- |
| Pi Web 起動時 | `pi-web.service` の `ExecStartPre=-+/usr/local/bin/pi-web-duckdns-update` |
| 起動 30 秒後 | `pi-web-duckdns.timer`（`OnBootSec=30s`） |
| 以後 5 分ごと | 同タイマー（`OnUnitActiveSec=5min`） |
| 手動 | `sudo /usr/local/bin/pi-web-duckdns-update` |

手動実行の確認:

```bash
sudo /usr/local/bin/pi-web-duckdns-update
# [duckdns] 更新しました（198.51.100.7 -> 203.0.113.42）  など

systemctl list-timers pi-web-duckdns.timer
journalctl -u pi-web-duckdns.service -n 20 --no-pager
```

> **失敗しても Pi Web は起動する**（`ExecStartPre` に `-` を付けているため）。
> DNS が古いままでも、ローカルの Pi Web 自体は動き続ける。

---

## 5. 確認

```bash
# 名前が今の IP を向いているか
dig +short mypi.duckdns.org
curl -s https://checkip.amazonaws.com

# Pi Web（ローカル）
curl -sI http://127.0.0.1:30141 | head -1

# Basic 認証（401 が返ればOK）
curl -sI https://mypi.duckdns.org | head -1

# 認証付きで通る
curl -sI -u 'pi:<パスワード>' https://mypi.duckdns.org | head -1
```

---

## 6. EC2 特有のハマりどころ

| 症状 | 原因 / 対処 |
| --- | --- |
| stop/start 後に繋がらない | DuckDNS 更新がまだ。`sudo /usr/local/bin/pi-web-duckdns-update` → 1〜2分待つ（TTL 60s + キャッシュ） |
| 証明書が取れない | SG で 443 が閉じている。`docker compose logs caddy` を確認。DNS が古いと TLS-ALPN-01 も失敗する |
| `docker build` が Killed | メモリ不足（t3.micro）。swap 追加 or t3.small 以上 |
| 更新が `KO` を返す | DuckDNS のトークン誤り。`/etc/pi-web/duckdns.env` を確認 |
| 更新が「取得できませんでした」 | アウトバウンド 443 が塞がれている / NAT GW なしのプライベートサブネット |
| `pi-web` が起動直後に落ちる | `journalctl -u pi-web -n 50`。Node 22 未満 / `PI_WEB_ALLOWED_HOSTS` 不一致 |
| Caddy から Pi Web に届かない | `docker-compose.yml` が `network_mode: host` か確認（Pi Web は 127.0.0.1 のみ待ち受けのため、ブリッジ経由では届かない）。`ss -ltn \| grep 30141` が `127.0.0.1:30141` か |
| 443 が使用中で Caddy が起動しない | `network_mode: host` はホストの 443 を直接使う。既存の nginx/apache を止めるか、`ss -ltnp \| grep :443` で占有元を確認 |

---

## 7. 運用

```bash
cd pi-web-remote && git pull
sudo systemctl restart caddy-native  # ネイティブ（設定変更時。admin off なので reload 不可）
# sudo systemctl restart caddy       # Docker 版を使っている場合
sudo systemctl restart pi-web      # Pi Web（起動時に DuckDNS も更新される）
```

**バックアップ**（Pi Web のデータは `/home/piweb/.pi/agent`）:

```bash
sudo tar czf ~/pi-web-backup-$(date +%F).tar.gz -C /home/piweb .pi .config/pi-web
```

**コスト**: t3.small 常時起動で月 $15 前後。EIP を取らないので、停止中の EIP 課金はなし
（停止中はインスタンスのコンピュート課金も止まる）。

---

## 8. セキュリティ・チェックリスト

- [ ] SG の 443 / 22 は自分の IP のみ。80 と 30141 は閉じている
- [ ] IAM ロールを付けていない（または最小権限）。IMDSv2 必須（`HttpTokens=required`）
- [ ] `piweb` ユーザーから `169.254.169.254` を遮断（`user-data.sh` に含む／更新スクリプトは root 実行なので影響なし）
- [ ] Pi Web は `-H 127.0.0.1`、Basic 認証と Pi Web パスワードは別の値
- [ ] `/etc/pi-web/duckdns.env` は 600、`.env.caddy` も 600 で Git 管理外
- [ ] `docker compose logs caddy` の 401 連発を時々確認
- [ ] EBS スナップショット or 上記 tar でバックアップ

---

## 付録: EIP を使わない代わりの選択肢

| 方法 | 特徴 |
| --- | --- |
| **DuckDNS 自動更新**（このページ） | 無料・URL 固定。切替時に数秒〜数十秒の穴 |
| **Cloudflare Tunnel** | IP 変動の影響ゼロ。ポート開放も不要。常用ならこれが一番安定 |
| **AWS Global Accelerator / ALB** | 固定 IP が得られるがコスト高（Pi Web 1個には過剰） |
