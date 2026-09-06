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

## メール送信

**Mailpit は開発専用**（`compose.override.yaml` にしか無く、本番構成には居ない）。本番は `.env` の
`MAILER_DSN` に実メールサービスの SMTP を書く:

```bash
MAILER_DSN=smtp://user:pass@smtp.example.com:587      # SendGrid / Amazon SES / さくら 等
```

- 未設定だと `null://null` で**注文メール・会員登録・パスワード再発行が黙って破棄**される。
  Mailpit 宛てのままだと本番には居ないホストへ送って失敗する。どちらも画面は正常に見える
- `bin/publish.sh` はこの 2 つを止める（`FORCE_PUBLISH=1` で無視できる）。`bin/plugin.sh doctor` も本番で警告する
- 送信元アドレスは管理画面 → 設定 → 店舗設定 → メール設定。送信ドメインの SPF / DKIM は
  メールサービス側の手順に従う（無いと迷惑メールに入る）

---

[← README へ戻る](../README.md)
