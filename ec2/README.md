# EC2 で動かす

`../duckdns/` の構成（Caddy + Basic 認証 + Pi Web）を EC2 上に置く手順。
自宅サーバと違い、**CGNAT の心配がなく、ポート開放の代わりにセキュリティグループを設定**する。

```
[インターネット]
      │ 443（SG で送信元 IP を制限）
      ▼
[EC2: Elastic IP]
   ├ Caddy (Docker)  … Let's Encrypt / Basic 認証
   └ Pi Web (systemd, 専用ユーザー piweb, 127.0.0.1:30141)
```

---

## 0. 先に決めること

| 項目 | 推奨 | 理由 |
| --- | --- | --- |
| AMI | **Ubuntu 24.04 LTS** | docker / NodeSource の手順が素直 |
| インスタンス | **t3.small (2GB)** 以上 | Caddy の自前ビルド（xcaddy）に 1GB では足りないことがある。t3.micro なら swap 必須（`user-data.sh` が 2GB 作成） |
| Elastic IP | **必ず割り当てる** | パブリック IP は stop/start で変わる。EIP があれば DuckDNS の更新 cron も不要 |
| IAM ロール | **付けない** | エージェントが bash を実行できるため、ロールがあると資格情報を読まれうる |

> **DuckDNS を使わない選択肢**: EIP で IP が固定なら `13-113-1-2.sslip.io` のような
> 名前がそのまま使える。Caddy は **TLS-ALPN-01（443 のみ）** で証明書を取れるので、
> 80 番も DNS トークンも不要になる。DNS-01 にこだわる理由がなければこちらが楽。
> DuckDNS を使う場合はドメインを Caddy の `DUCKDNS_DOMAIN` に入れるだけで、他は同じ。

---

## 1. セキュリティグループ

**443 は自分の IP だけ**に絞る。22 も同様。80 と 30141 は開けない。

| タイプ | ポート | 送信元 | 用途 |
| --- | --- | --- | --- |
| HTTPS | 443 | `203.0.113.5/32`（自分の IP） | Pi Web |
| HTTPS (UDP) | 443 | 同上 | HTTP/3（任意） |
| SSH | 22 | 自分の IP | 管理 |

```bash
SG=sg-xxxxxxxx
MYIP=$(curl -s https://ifconfig.me)/32

aws ec2 authorize-security-group-ingress --group-id $SG --ip-permissions \
  "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$MYIP,Description=\"pi-web\"}]" \
  "IpProtocol=udp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=$MYIP,Description=\"pi-web-h3\"}]" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MYIP,Description=\"ssh\"}]"

# デフォルトで開いている 0.0.0.0/0 の 22/80/443 があれば閉じる
aws ec2 describe-security-groups --group-ids $SG --query 'SecurityGroups[0].IpPermissions' -o json
aws ec2 revoke-security-group-ingress --group-id $SG \
  --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]'
```

> 常時 443 を全世界に開けるなら、Caddyfile の IP 制限コメントを有効化するか、
> 少なくとも Basic 認証のパスワードを 32 文字ランダムにする。

---

## 2. 起動と初期設定

インスタンス起動時、**「高度な詳細 > ユーザーデータ」に `user-data.sh` を貼る**。

手動でやる場合は起動後に:

```bash
# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu    # 再ログイン

# Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# Pi Web 専用ユーザー
sudo useradd -m -s /bin/bash piweb
sudo install -d -o piweb -g piweb /home/piweb/.config/pi-web
```

Elastic IP を関連付けたら、DuckDNS を使う場合は IP を反映:

```bash
curl "https://www.duckdns.org/update?domains=mypi&token=<TOKEN>&ip=$(curl -s https://ifconfig.me)"
```

---

## 3. デプロイ

```bash
# コード
git clone https://github.com/soubell/pi-web-remote.git
cd pi-web-remote/duckdns

# .env.caddy（ドメイン / token / Basic 認証）
sudo -u ubuntu ./setup.sh     # docker グループに入っている自ユーザーで実行

# Pi Web の環境変数（秘密情報なので 600 で）
sudo tee /home/piweb/.config/pi-web/env >/dev/null <<EOF
PI_WEB_PASSWORD=$(openssl rand -base64 32)
PI_WEB_ALLOWED_HOSTS=mypi.duckdns.org
PI_WEB_IDLE_TIMEOUT_MS=0
PI_WEB_NO_OPEN=1
EOF
sudo chown piweb:piweb /home/piweb/.config/pi-web/env
sudo chmod 600 /home/piweb/.config/pi-web/env

# systemd
sudo cp ../ec2/pi-web.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pi-web
systemctl status pi-web --no-pager

# Caddy
docker compose up -d --build
docker compose logs -f caddy    # 証明書取得のログ
```

---

## 4. 確認

```bash
# ローカルの Pi Web
curl -sI http://127.0.0.1:30141 | head -1

# Basic 認証が効いている（401 が返ればOK）
curl -sI https://mypi.duckdns.org | head -1

# 認証付きで通る
curl -sI -u 'pi:<パスワード>' https://mypi.duckdns.org | head -1

# 証明書
openssl s_client -connect mypi.duckdns.org:443 -servername mypi.duckdns.org </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

---

## 5. EC2 特有のハマりどころ

| 症状 | 原因 / 対処 |
| --- | --- |
| 証明書が取れない | SG で 443 が閉じている（TLS-ALPN-01 の場合）。DNS-01 なら DuckDNS の token を確認 |
| 数日で繋がらなくなる | Elastic IP 未割り当てでパブリック IP が変わった → EIP を割り当てる |
| `docker build` が Killed | メモリ不足（t3.micro）。swap 追加 or t3.small 以上 |
| `pi-web` が起動直後に落ちる | `journalctl -u pi-web -n 50`。Node 22 未満 / `PI_WEB_ALLOWED_HOSTS` 不一致 |
| Caddy から Pi Web に届かない | `extra_hosts: host.docker.internal:host-gateway` が有効か、`ss -ltnp \| grep 30141` が 127.0.0.1 か |
| 認証情報を読まれた疑い | IMDSv2 必須 + `user-data.sh` の iptables で `piweb` から 169.254.169.254 を遮断済みか確認 |

---

## 6. 運用

**更新**

```bash
cd pi-web-remote && git pull
cd duckdns && docker compose up -d --build   # Caddy
sudo systemctl restart pi-web                # Pi Web（npx なので毎回最新を取得）
```

**ログ**

```bash
docker compose logs -f caddy          # アクセスログ（401 の連発を監視）
journalctl -u pi-web -f
```

**バックアップ**: Pi Web のデータは `/home/piweb/.pi/agent`（セッション・設定）。
`/home/piweb/.config/pi-web/env` と併せて取得しておく。

```bash
sudo tar czf ~/pi-web-backup-$(date +%F).tar.gz \
  -C /home/piweb .pi .config/pi-web
```

**コスト**: t3.small を常時起動で月 $15 前後（+ EIP はインスタンス起動中は無料）。
使わない時間があるなら停止し、その間は EIP が課金対象（月 $3.6 程度）になる点に注意。

---

## 7. セキュリティ・チェックリスト

- [ ] SG の 443 / 22 は自分の IP のみ。80 と 30141 は閉じている
- [ ] Elastic IP を関連付け（IP 固定）
- [ ] IAM ロールを付けていない（または最小権限）。IMDSv2 必須（`HttpTokens=required`）
- [ ] `piweb` ユーザーから `169.254.169.254` を遮断（`user-data.sh` に含む）
- [ ] Pi Web は `-H 127.0.0.1`、Basic 認証と Pi Web パスワードは別の値
- [ ] EBS / インスタンスのバックアップ（スナップショット or 上記 tar）
- [ ] `docker compose logs caddy` の 401 連発を時々確認
