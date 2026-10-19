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

## 3. デプロイ

```bash
git clone https://github.com/soubell/pi-web-remote.git
cd pi-web-remote/duckdns
./setup.sh                 # DuckDNS ドメイン / token / Basic 認証 → .env.caddy

cd ../ec2
sudo ./install.sh          # DuckDNS 自動更新フック + systemd ユニットを配置
```

`install.sh` がやること:

| 配置物 | 役割 |
| --- | --- |
| `/etc/pi-web/duckdns.env` (600) | DuckDNS のドメインとトークン |
| `/usr/local/bin/pi-web-duckdns-update` | 現在のパブリック IP を取得して A レコードを更新 |
| `pi-web-duckdns.timer` | 起動 30 秒後 + **5 分ごと** |
| `pi-web.service` | `ExecStartPre` で更新 → Pi Web 起動 |
| `caddy.service` | compose を systemd 管理（`After=pi-web-duckdns.service`） |

続いて Pi Web の秘密情報と起動:

```bash
sudo tee /home/piweb/.config/pi-web/env >/dev/null <<EOF
PI_WEB_PASSWORD=$(openssl rand -base64 32)
PI_WEB_ALLOWED_HOSTS=mypi.duckdns.org
PI_WEB_IDLE_TIMEOUT_MS=0
PI_WEB_NO_OPEN=1
EOF
sudo chown piweb:piweb /home/piweb/.config/pi-web/env
sudo chmod 600 /home/piweb/.config/pi-web/env

sudo systemctl enable --now pi-web
sudo systemctl enable --now caddy     # docker compose up -d --build 相当
```

> `PI_WEB_PASSWORD` を後から確認したい場合は
> `sudo cat /home/piweb/.config/pi-web/env`（root のみ）。

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
| Caddy から Pi Web に届かない | `extra_hosts: host.docker.internal:host-gateway` と `ss -ltnp \| grep 30141` を確認 |

---

## 7. 運用

```bash
cd pi-web-remote && git pull
sudo systemctl restart caddy       # Caddy（docker compose 再ビルド）
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
