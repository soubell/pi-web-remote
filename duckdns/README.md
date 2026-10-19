# DuckDNS + Caddy（Basic 認証）で公開する

自前ドメイン（DuckDNS）で **HTTPS 終端**し、入口を **Basic 認証**で守る構成。
Pi Web 自身のパスワードは第2層として残る。**ポート開放（443）が必要**。

```
[ブラウザ]
    │ HTTPS 443
    ▼
[ルータ: 443 転送]
    ▼
[Caddy]  Let's Encrypt 証明書（DNS-01 / DuckDNS API → 80番不要）
    │    Basic 認証（第1層）
    ▼
[Pi Web 127.0.0.1:30141]  PI_WEB_PASSWORD（第2層）
```

> **なぜ Basic 認証を重ねるか**: Pi Web の認証はパスワード1個だけで、試行制限もない。
> Caddy 側で別のパスワードを要求すると、片方が漏れても即突破されない。
> IP 制限を併用すれば実用上かなり堅くなる（`Caddyfile` にコメントで雛形あり）。

---

## 0. 事前チェック（ここで決まる）

```bash
curl -s https://ifconfig.me; echo
```

ルータ管理画面の **WAN 側 IP** と一致するか確認する。

| 結果 | 判断 |
| --- | --- |
| 一致 | ✅ この手順でOK |
| 不一致（`100.64.*` / `10.*` / `172.16-31.*` など） | ❌ **CGNAT**。ポート開放は不可 → `../ngrok/` か Cloudflare Tunnel / Tailscale へ |

日本の光回線（v6プラス / transix / NURO など）は CGNAT が多い。ここで不一致なら
このディレクトリの話は無意味になるので、必ず先に確認する。

---

## 1. DuckDNS の準備

1. https://www.duckdns.org にログイン
2. `mypi` などを入力 → **add domain** → `mypi.duckdns.org`
3. ページ上部の **token** を控える（ACME の DNS-01 にも使う）
4. 現在の IP を反映

```bash
curl "https://www.duckdns.org/update?domains=mypi&token=<TOKEN>&ip="
# OK が返れば成功
```

**IP の自動追従**（家庭回線なら必須）:

```cron
*/5 * * * * curl -fsS "https://www.duckdns.org/update?domains=mypi&token=<TOKEN>&ip=" >/dev/null
```

---

## 2. セットアップ

```bash
cd duckdns
./setup.sh
```

対話で聞かれるもの: DuckDNS ドメイン / token / ACME メール / Basic 認証のユーザー名・パスワード。

`setup.sh` がやること:

- `caddy hash-password` で **bcrypt ハッシュ**を生成（パスワードは stdin から渡すので `ps` に残らない）
- `.env.caddy` に書き出して `chmod 600`
- `$` を含むハッシュは `env_file` 経由で渡すので、compose の変数展開に壊されない

> 自前ビルドを避けたい場合は `ghcr.io/ivanndotco/caddy_xcaddy_duckdns` のような
> ビルド済みイメージもあるが、第三者のビルドを信頼することになる。`Dockerfile` の
> `xcaddy build` は数十秒なので、自前ビルドを推奨。

---

## 3. Pi Web を起動（ホスト側、127.0.0.1 のみ）

```bash
PI_WEB_PASSWORD='(32文字ランダム)' \
PI_WEB_ALLOWED_HOSTS='mypi.duckdns.org' \
PI_WEB_IDLE_TIMEOUT_MS=0 \
npx @agegr/pi-web@latest -H 127.0.0.1 -p 30141 --no-open
```

- `PI_WEB_ALLOWED_HOSTS` は **完全一致**。忘れると 403
- 常駐化は `../agent/pi-web.service`（systemd ユーザーサービス）を参照

---

## 4. 起動と確認

```bash
docker compose up -d --build
docker compose logs -f caddy     # 初回は DNS-01 の伝播待ちで 30〜90 秒
```

成功ログの例: `certificate obtained successfully identifier=mypi.duckdns.org`

ブラウザで `https://mypi.duckdns.org` → **Basic 認証** → **Pi Web のパスワード**、の2段階。

```bash
# 401 が返れば Basic 認証は効いている
curl -sI https://mypi.duckdns.org | head -1
# 証明書の確認
openssl s_client -connect mypi.duckdns.org:443 -servername mypi.duckdns.org </dev/null 2>/dev/null | openssl x509 -noout -subject -dates
```

---

## 5. Caddyfile のポイント

| 設定 | 意味 |
| --- | --- |
| `tls { dns duckdns ... }` | TXT レコードで所有証明。**ポート80不要** |
| `propagation_delay 30s` | DuckDNS の TXT 反映遅延への保険 |
| `basic_auth` | Pi Web とは**別のパスワード**。総当たりの手前で止める |
| `@notme not remote_ip ...` | 有効化すると IP 制限。自宅・社内だけに絞れる |
| `flush_interval -1` | SSE（Pi Web のストリーミング）をバッファリングしない |
| `read_timeout 1h` | 長時間のエージェント実行で切れないように |
| `caddy_data` ボリューム | 証明書の保存先。消すと再取得で Let's Encrypt のレート制限に当たる |

---

## 6. ハマりどころ

| 症状 | 原因 / 対処 |
| --- | --- |
| `403 Invalid host` | `PI_WEB_ALLOWED_HOSTS` にドメインを完全一致で追加 |
| 証明書が取れない | `docker compose logs caddy`。DuckDNS の token 誤り / TXT 反映待ちが大半。`propagation_delay` を 60s に |
| Basic 認証を何度も聞かれる | ハッシュが壊れている（`$` の二重展開）。`env_file` 経由か確認し、`environment:` に移すなら `$$` にエスケープ |
| 画面が途中で止まる | SSE。`flush_interval -1` が消えていないか確認 |
| `curl` は通るがブラウザで繋がらない | HTTP/3 (UDP 443) を塞いでいる場合は TCP でフォールバックするので通常は問題なし。プロキシ環境は注意 |

---

## 7. セキュリティ

トンネル型（ngrok / Cloudflare）と違い、**世界中から 443 に直接到達できる**状態になる。

- 公開ポートは **443 のみ**。80 / Pi Web のポートは閉じる
- Basic 認証と Pi Web パスワードは**別の値**（`openssl rand -base64 32`）
- 可能なら IP 制限（Caddyfile のコメントを有効化）や fail2ban を併用
- `docker compose logs caddy` に 401 の連発が出ていないか時々見る
- Pi Web は**専用ユーザー**で実行し、`~/.ssh`・クラウド認証情報を置かない
- `.env.caddy` は絶対にコミットしない（`.gitignore` 済み）
