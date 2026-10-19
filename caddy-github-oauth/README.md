# 方式A: DuckDNS + Caddy + GitHub OAuth

自前ドメイン（DuckDNS）で **HTTPS 終端**し、入口を **GitHub ログイン**で守る構成。
Pi Web 自身のパスワードは第2層として残る。**ポート開放（443）が必要**。

```
[ブラウザ]
    │ HTTPS 443
    ▼
[ルータ: 443 転送]
    ▼
[Caddy]  Let's Encrypt 証明書（DNS-01 / DuckDNS API → 80番不要）
    ├─ /oauth2/*  ──────────────► [oauth2-proxy]  GitHub OAuth
    └─ それ以外 ─ forward_auth ─► [Pi Web 127.0.0.1:30141]
                                  └ PI_WEB_PASSWORD（第2層）
```

**なぜ GitHub OAuth を挟むか**: Pi Web の認証はパスワード1個だけで、総当たり以外の防御がない。
oauth2-proxy を前段に置くと「GitHub アカウントでログインできた人だけ」に絞れるので、
パスワードが漏れても第三者は入れない（逆も同様）。実質二要素に近い。

---

## 0. 事前チェック（ここで決まる）

```bash
curl -s https://ifconfig.me; echo
```

ルータ管理画面の **WAN 側 IP** と一致するか確認する。

| 結果 | 判断 |
| --- | --- |
| 一致 | ✅ この手順でOK |
| 不一致（`100.64.*` / `10.*` / `172.16-31.*` など） | ❌ **CGNAT**。ポート開放は不可 → `../cloudflare-tunnel/` か Tailscale へ |

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

## 2. GitHub OAuth App を作る

https://github.com/settings/developers → **New OAuth App**

| 項目 | 値 |
| --- | --- |
| Application name | `Pi Web` |
| Homepage URL | `https://mypi.duckdns.org` |
| Authorization callback URL | `https://mypi.duckdns.org/oauth2/callback` |

作成後に **Client ID** と **Client Secret** を控える（Secret は再表示できないので注意）。

> **スコープ**: OAuth App は `read:user` 相当のみ。リポジトリへの権限は要求しない。
> アクセス制御は `OAUTH2_PROXY_GITHUB_USER` に**自分の login 名**を入れることで行う
> （未設定だと GitHub アカウントを持つ全員がログインできてしまうので必須）。
> org / team で縛るなら `OAUTH2_PROXY_GITHUB_ORG` / `OAUTH2_PROXY_GITHUB_TEAM` を使う。

---

## 3. セットアップ

```bash
cd caddy-github-oauth
./setup.sh
```

対話で聞かれるもの: DuckDNS ドメイン / token / ACME メール / GitHub Client ID・Secret / 許可ユーザー名。

生成されるファイル（**どちらも `chmod 600`、`.gitignore` 済み**）:

| ファイル | 内容 |
| --- | --- |
| `.env.caddy` | DuckDNS ドメイン・token、Pi Web の upstream |
| `.env.oauth` | GitHub の Client ID/Secret、cookie secret（自動生成）、許可ユーザー |

> cookie secret には `+` `/` が入りうるため、base64url に変換して生成している。
> `env_file` 経由で渡すので `$` の変数展開に壊されない。

---

## 4. Pi Web を起動（ホスト側、127.0.0.1 のみ）

```bash
PI_WEB_PASSWORD='(32文字ランダム)' \
PI_WEB_ALLOWED_HOSTS='mypi.duckdns.org' \
PI_WEB_IDLE_TIMEOUT_MS=0 \
npx @agegr/pi-web@latest -H 127.0.0.1 -p 30141 --no-open
```

- `PI_WEB_ALLOWED_HOSTS` は **完全一致**。忘れると 403
- 常駐化は `../agent/pi-web.service`（systemd ユーザーサービス）を参照

---

## 5. 起動と確認

```bash
docker compose up -d --build
docker compose logs -f caddy     # 初回は DNS-01 の伝播待ちで 30〜90 秒
```

成功ログの例: `certificate obtained successfully identifier=mypi.duckdns.org`

ブラウザで `https://mypi.duckdns.org` → **GitHub ログイン** → **Pi Web のパスワード**、の2段階。

### 動作チェック

```bash
curl -sI https://mypi.duckdns.org | grep -iE '^(HTTP|location)'   # 302 → /oauth2/start
curl -s  https://mypi.duckdns.org/oauth2/sign_in | head           # ログイン画面
```

---

## 6. Caddyfile のポイント

| 設定 | 意味 |
| --- | --- |
| `tls { dns duckdns ... }` | TXT レコードで所有証明。**ポート80不要** |
| `propagation_delay 30s` | DuckDNS の TXT 反映遅延への保険 |
| `handle /oauth2/*` | コールバックは認証対象外にする（これを忘れるとログインループ） |
| `forward_auth ... uri /oauth2/auth` | サブリクエストで cookie 検証。OK なら次へ |
| `flush_interval -1` | SSE（Pi Web のストリーミング）をバッファリングしない |
| `read_timeout 1h` | 長時間のエージェント実行で切れないように |
| `caddy_data` ボリューム | 証明書の保存先。消すと再取得で Let's Encrypt のレート制限に当たる |

---

## 7. ハマりどころ

| 症状 | 原因 / 対処 |
| --- | --- |
| ログイン後に無限リダイレクト | `OAUTH2_PROXY_REDIRECT_URL` と GitHub の callback URL が不一致（`https` と末尾の有無まで合わせる） |
| `403 Invalid host` | `PI_WEB_ALLOWED_HOSTS` にドメインを完全一致で追加 |
| `cookie_secret` エラー | 16/24/32 バイトでない。`./setup.sh` の生成値を使う |
| 証明書が取れない | `docker compose logs caddy`。DuckDNS の token 誤り / TXT 反映待ちが大半。`propagation_delay` を 60s に |
| 画面が途中で止まる | SSE。`flush_interval -1` が消えていないか確認 |
| ログインできる人が限定されない | `OAUTH2_PROXY_GITHUB_USER` が空。必ず設定する |

---

## 8. セキュリティ

トンネル型（ngrok / Cloudflare）と違い、**世界中から 443 に直接到達できる**状態になる。

- 公開ポートは **443 のみ**。80 / Pi Web のポートは閉じる
- GitHub ログインで絞った上で、Pi Web のパスワードも必ず設定（別の値）
- 可能なら Caddy で IP 制限（`@ok remote_ip 203.0.113.0/24`）や fail2ban を併用
- `docker compose logs caddy` に 401/403 の連発が出ていないか時々見る
- Pi Web は**専用ユーザー**で実行し、`~/.ssh`・クラウド認証情報を置かない
- `.env.caddy` / `.env.oauth` は絶対にコミットしない（`.gitignore` 済み）
