# syntax=docker/dockerfile:1
# 公式 Caddy に DuckDNS の DNS-01 プロバイダを組み込んだ自前ビルド
FROM caddy:2.11-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/duckdns

FROM caddy:2.11
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
