# 本番デプロイ

どのサーバーでも同じ手順で公開する。**すでに動いている本番を上げる場合は [バージョンアップ](upgrade.md)。**


すでに動いている本番を**新しいバージョンへ上げる**場合は、この節ではなく
「[バージョン切替 / バージョンアップ](upgrade.md)」を見ること。
`bin/publish.sh` は起動するだけで、本体コードの入れ替えと migration は行わない。


```bash
# .env で公開方式を選ぶ（COMPOSE_PROFILES）
bin/publish.sh   # compose.prod.yaml を重ねて起動（配布イメージなら pull、なければ build）
```

| プロファイル | 公開方式 | 開けるポート |
|---|---|---|
| `tunnel` | Cloudflare Tunnel（既定） | なし（outbound のみ） |
| `caddy` | Caddy 自動 HTTPS（Let's Encrypt） | 80 / 443 |
| （未設定） | host nginx / AWS ALB の背後 | なし（127.0.0.1 束縛） |

- **tunnel**: `.env` に `TUNNEL_TOKEN` を設定。ダッシュボードで公開ホスト名 → `http://nginx:80`。
- **caddy**: `.env` に `SITE_DOMAIN` を設定し、A レコードをこのサーバーへ向ける。
- **背後配置**: `COMPOSE_PROFILES` を空にすると nginx は `127.0.0.1:8080` のみで待ち受ける。

---

[← README へ戻る](../README.md)
