# Pi Web を外部に公開する構成（テンプレート集）

`pi coding agent` の Web UI である [Pi Web](https://github.com/agegr/pi-web) は
標準では `127.0.0.1:30141` だけで待ち受ける。ここでは「外から使う」ための構成を、
**安全側に倒した形**でまとめている。

> ⚠️ Pi Web は **エージェントが bash を実行できる** UI であり、認証はパスワード1個だけ、
> 通信は平文 HTTP。要するに「公開した瞬間、URL とパスワードを知る人はあなたの権限で
> 何でもできる」。どの構成でも **前段の認証（Basic 認証 / VPN）を必ず重ねる**こと。

---

## まず最初にやる: CGNAT 判定

自宅回線で「ポート開放できるか」を 30 秒で確認する。ここで結論が変わる。

```bash
curl -s https://ifconfig.me; echo
```

ルータ管理画面の **WAN 側 IP** と比較:

| 結果 | 意味 | 選ぶ方式 |
| --- | --- | --- |
| 一致 | グローバル IP を直接保有 | **方式A**（自前ドメイン）が使える |
| 不一致（`100.64.*` / `10.*` / `172.16-31.*`） | **CGNAT**（IPv4 over IPv6 / MAP-E / DS-Lite） | **方式B**（トンネル）一択 |

日本の光回線は CGNAT が多い（v6プラス、transix、NURO 等）。不一致なら方式Aは不可能。

---

## 方式の比較

| | A: DuckDNS + Caddy + Basic 認証 | B: Cloudflare Tunnel + Access | C: ngrok + Basic 認証 |
| --- | --- | --- | --- |
| 置き場所 | `duckdns/` | （今後追加予定） | `ngrok/` |
| ポート開放 | **必要（443）** | 不要 | 不要 |
| CGNAT | ❌ 不可 | ✅ 可 | ✅ 可 |
| 認証 | Basic 認証（+ 任意で IP 制限） | Google/GitHub ログイン | Basic 認証 |
| ドメイン | DuckDNS（無料） | 自前ドメイン必要 | 不要（`*.ngrok-free.app`） |
| 帯域 | 回線次第 | 無制限（無料） | 1GB/月（無料） |
| HTTPS | Let's Encrypt | Cloudflare | ngrok |
| 向く用途 | 固定IP・自分専用 | **常用（一番おすすめ）** | 一時的な確認 |

**結論**: 常用するなら **方式B**。CGNAT でなく、自分しか使わず IP 制限もかけられるなら **方式A**。
「5分だけ見せたい」なら **方式C**。

---

## ディレクトリ

```
duckdns/   DuckDNS + Caddy（Let's Encrypt DNS-01）+ Basic 認証   … 方式A（自宅/VPS/EC2 共通）
ec2/       EC2 デプロイ手順・cloud-init・systemd ユニット        … 方式A を EC2 で動かす
ngrok/     ngrok + Basic 認証 + Pi Web パスワード                 … 方式C（一時利用）
agent/     systemd ユーザーサービス（汎用）
```

---

## 共通の前提

- Node.js 22.19.0 以上
- Pi Web は **`127.0.0.1` にだけバインド**（`-H 127.0.0.1`）
- 前段が送ってくるホスト名を `PI_WEB_ALLOWED_HOSTS` に**完全一致**で追加（忘れると 403）
- `PI_WEB_IDLE_TIMEOUT_MS=0`（既定 10 分で勝手に落ちるのを防ぐ）
- Pi Web のパスワードは前段の認証とは**別の値**にする（`openssl rand -base64 32`）

## 秘密情報の扱い

- `.env` / `.env.*` / `*.pem` / `password` / `policy.yml` は `.gitignore` 済み
- リポジトリにコミットするのは **`.example` 雛形だけ**
- 漏れた疑いがあれば、パスワード変更 → cookie secret 等の再生成 → 証明書・トンネル再作成

## 参考

- Pi Web README: https://github.com/agegr/pi-web
- インタラクティブデモ（インストール不要）: https://agegr.github.io/pi-web/
- Pi Web のリモート公開に関する注意: 同 README の "Remote Access"
