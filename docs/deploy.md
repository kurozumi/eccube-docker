# 本番デプロイ

どのサーバーでも同じ手順で公開する。**すでに動いている本番を上げる場合は [バージョンアップ](upgrade.md)。**


すでに動いている本番を**新しいバージョンへ上げる**場合は、この節ではなく
「[バージョン切替 / バージョンアップ](upgrade.md)」を見ること。
`bin/publish.sh` は起動するだけで、本体コードの入れ替えと migration は行わない。


## サーバーを整える（手元から）

```bash
bin/bootstrap-server.sh user@host /srv/myshop      # Docker を入れ、店のファイルを送り、.env を作る
bin/setup.sh mail --remote=user@host:/srv/myshop   # メール（先に 1 通試す）
bin/publish.sh --remote=user@host:/srv/myshop      # 公開
```

`bootstrap-server.sh` は Ubuntu / Debian の VPS を想定（Docker は get.docker.com の手順で入れる。
sudo が使えること）。**サーバーに git も GitHub の鍵も置かない。** 店のファイルは手元から rsync で
送り、以後の反映も `bin/deploy.sh --remote=…` が手元から送る（**push モード**。サーバーに `.git` が
あれば今までどおり向こうで `git pull` する **pull モード**。`--push` / `--pull` で強制できる）。
push で上書きされたファイルはサーバーの `var/deploy-prev/<日時>/` に残る。

手元の `.env` に `ECCUBE_IMAGE` があればサーバーにも書く（配布イメージを pull するだけで済む。
無いとサーバーで build するので 10 分以上かかる）。

## 公開方式

```bash
# .env で公開方式を選ぶ（COMPOSE_PROFILES）
bin/publish.sh   # compose.prod.yaml を重ねて起動（配布イメージなら pull、なければ build）
```

| プロファイル | 公開方式 | 開けるポート |
|---|---|---|
| `tunnel` | Cloudflare Tunnel（既定） | なし（outbound のみ） |
| `caddy` | Caddy 自動 HTTPS（Let's Encrypt） | 80 / 443 |
| （未設定） | host nginx / AWS ALB の背後 | なし（127.0.0.1 束縛） |

- **tunnel**: **`bin/setup.sh tunnel`**（トークンを貼る → 繋がるか試す → 通れば `.env` に書く。
  Cloudflare の画面でやることも表示する）。手でやるなら `.env` に `TUNNEL_TOKEN`、ダッシュボードで
  公開ホスト名 → `http://nginx:80`。
- **caddy**: `.env` に `SITE_DOMAIN` を設定し、A レコードをこのサーバーへ向ける。
- **背後配置**: `COMPOSE_PROFILES` を空にすると nginx は `127.0.0.1:8080` のみで待ち受ける。

## メール送信

**Mailpit は開発専用**（`compose.override.yaml` にしか無く、本番構成には居ない）。本番は
**`bin/setup.sh mail`** で設定する（サービスを選んで質問に答える → 1 通試しに送る → 届けば `.env` に書く）。
手で書くなら `.env` の `MAILER_DSN`:

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
