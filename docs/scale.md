# 大規模アクセス / スケール

1台で捌く（Tier 1）→ 状態を外に出す（Tier 2）→ 複数ホスト、の順に進める。


段階的にスケールできる構成になっている（すべて実機検証済み・本体は非編集）:

| 段階 | 内容 | 節 |
|---|---|---|
| Tier 1 | 単一ホスト強化（php-fpm / OPcache / Redis キャッシュ / DB / nginx） | この節 |
| Tier 1 | 1台内の水平スケール（`--scale` 内部ロードバランス） | 水平スケール |
| Tier 2 | セッションの Redis 共有 | セッションの Redis 共有 |
| Tier 2 | アップロード画像の共有ストレージ（NFS/EFS） | アップロード画像 |
| Tier 2 | 複数ホスト + 外部 LB（`compose.app.yaml`） | 複数ホスト + LB |

## 単一ホスト強化（Tier 1）

（Redis キャッシュは任意。`COMPOSE_PROFILES` に `redis` を足したときだけ。単一ホストなら無くても動く）

単一ホストのまま高トラフィックに耐えるための強化が入っている。

| 強化 | 場所 | 調整 |
|---|---|---|
| php-fpm ワーカー数 | entrypoint が env から生成 | `.env` の `PHP_FPM_*` |
| 本番 OPcache（`validate_timestamps=0`） | entrypoint（`APP_ENV=prod` で自動） | — |
| Redis 共有キャッシュ（Symfony app cache・任意） | `COMPOSE_PROFILES` に `redis`（`app/config/eccube/optional/redis/`） | `REDIS_URL` |
| MariaDB バッファプール等 | `docker/mariadb/conf.d/eccube.cnf` | `innodb_buffer_pool_size` を RAM に合わせる |
| gzip / 静的長期キャッシュ | `docker/nginx/default.conf` | — |

**まず調整すべき2点**: `PHP_FPM_MAX_CHILDREN`（＝同時処理数。メモリから算出）と
`innodb_buffer_pool_size`（＝専用 DB なら RAM の 50〜70%）。

**DB 接続数の設計式**（特に複数ホスト時）:

```
Σ(各ホストの PHP_FPM_MAX_CHILDREN) + worker 数 + 管理用余裕(10〜20) ≦ max_connections(既定 200)
```

例: `MAX_CHILDREN=50` を 4 ホスト並べると 200 で即枯渇（Too many connections）。
`docker/mariadb/conf.d/eccube.cnf` の `max_connections` を上げるか、ホストあたりの
children を配分する。

## 水平スケール（1台の中で php-fpm を増やす）

```bash
docker compose up -d --scale ec-cube=3
```

nginx は Docker 内蔵 DNS を毎回引き直して各レプリカへ分散する（内部ロードバランス）。
実測で 2 レプリカに約 11:9 で振り分き、1 台停止時も残りが 200 を返し継続（フェイルオーバー）。

注意点:
- レプリカは同じ `eccube_app` ボリューム（`var/cache`）を共有するため、追加レプリカの
  起動時 `cache:clear` が稼働中レプリカのコンパイル済みキャッシュを一瞬消して 500 を
  出し得る。**スケール追加時はスキップフラグを付けて起動**する:
  ```bash
  ECCUBE_SKIP_DB_INIT=1 ECCUBE_SKIP_CACHE_CLEAR=1 docker compose up -d --scale ec-cube=3 --no-recreate
  ```
  （migrate / cache:clear は 1 台目が起動時に済ませている。追加分は何も触らない）
- `docker compose up` を `--scale` なしで実行すると台数が既定(1)に戻る。スケール状態を
  保つなら毎回 `--scale ec-cube=N` を付けるか、`deploy.replicas` を設定する。

# セッションの Redis 共有（Tier 2）

**初回は無効。** `.env` の `COMPOSE_PROFILES` に `redis` を足して `docker compose up -d`
（例: `COMPOSE_PROFILES=tunnel,redis`）。`redis` / `redis-session` の起動と、
`app/config/eccube/optional/redis/` の設定投入が同じ値で決まる。
**切り替えた瞬間、全員ログアウトになる**（ファイルに入っていたセッションは移らない。
カートも消える）。本番で有効にするなら時間を選ぶ。戻すときも同じ。

セッションは専用の `redis-session` サービス（永続化・`noeviction`）に保存される。
これにより **複数ホスト／複数レプリカでセッションが共有**され、ボリューム共有に依存せず
カート・ログインが保たれる（LB を前に置いても成立する）。

- 本体の `SameSiteNoneCompatSessionHandler`（決済リダイレクトの SameSite=None 対応）は
  維持したまま、その内側のハンドラだけを `Customize\Session\RawRedisSessionHandler` で
  Redis に差し替えている（`app/Customize/Resource/config/services.yaml`）。
- 接続先は `.env` の `SESSION_REDIS_URL`（本番はマネージド Redis に向けられる）。
- キャッシュ用 `redis`（`allkeys-lru`）とは別インスタンスにして、セッションが LRU で
  勝手に消えないようにしている。上限は `.env` の `SESSION_REDIS_MAXMEMORY`（既定 256mb）。
  到達時は OOM ではなく新規セッションの書込エラーになり、既存ユーザーは守られる。
- 単一ホストのみで運用するなら不要。この 3 定義（services.yaml）と `redis-session`
  サービスを外せばファイルセッションに戻る。

> 実測: ログイン系ページで発行される `eccube` セッション ID が `redis-session` に
> `ecses:<id>`（TTL≈`gc_maxlifetime`）として保存され、`--scale=2` でも両レプリカから
> 同一セッションを参照できることを確認済み。`var/sessions` には新規作成されない。

> 既知の挙動: Redis セッションは**非ロック**（同一セッションの同時リクエストは後勝ち）。
> これは Symfony 標準の RedisSessionHandler と同じ挙動で、通常のブラウジングでは
> 問題にならない（Ajax 多重発行等で稀にカート更新が競合し得る程度）。

# アップロード画像の共有ストレージ（Tier 2）

商品画像などのアップロードは `html/upload`（`save_image` / `temp_image`）に保存される。
これを **専用ボリューム `eccube_upload`** に分離してあり、アプリ（`eccube_app`）や DB とは
独立している。複数ホストで LB する場合、**あるホストで登録した画像を別ホストも見られる**
必要があるため、このボリュームを共有ストレージに向ける。

**複数ホスト共有（NFS の例）** — `compose.yaml` の `volumes:` を差し替える:

```yaml
volumes:
  eccube_upload:
    driver: local
    driver_opts:
      type: nfs
      o: "addr=10.0.0.10,rw,nfsvers=4"
      device: ":/export/eccube/upload"
```

AWS なら EFS を同様に指定する。**外部ストレージ側にデータがあるので、`down -v` でも
実データは失われない**（ローカルボリュームのままだと `down -v`＝`reset`/`switch-version`
で消える）。

**バックアップ / 移行**（ローカルボリューム運用時）:

```bash
docker compose cp ec-cube:/var/www/html/html/upload/. ./upload-backup/   # 退避
docker compose cp ./upload-backup/. ec-cube:/var/www/html/html/upload/   # 復元
```

> オブジェクトストレージ（S3 直結）にしたい場合は、EC-CUBE 側に S3 アダプタ（プラグイン
> またはサービス上書き）と画像配信の URL 変更が必要で、バージョン依存が大きい。まずは
> 本体無改造で済む共有ファイルシステム（NFS/EFS）方式を推奨。

# 複数ホスト + ロードバランサ

これまでの強化でアプリ層はステートレス（セッション/キャッシュ=Redis、画像=共有ストレージ、
DB=外部）になっているので、**アプリホストを N 台並べて前段に LB** を置ける。

## 構成

```
            ┌─ 外部 LB（HTTPS 終端 / nginx・Cloudflare LB・ALB）
            │        │ 振り分け
   ┌────────┴──┐  ┌──┴────────┐
   │ app host1 │  │ app host2 │  … 各ホストで compose.app.yaml（ec-cube+nginx）
   └────┬──────┘  └────┬──────┘
        └──────┬───────┘  すべて同じ外部サービスを参照
        共有: DB / Redis(cache) / Redis(session) / アップロード画像(NFS/EFS)
```

## 管理画面が書くファイルは 1 台にしか無い

管理画面は DB だけでなくファイルにも書く（ページ管理 → `app/template/user_data/`、ブロック管理 →
`app/template/<テーマ>/Block/`、CSS・JS 管理 → `html/user_data/assets/`、ファイル管理 →
`html/user_data/`、プラグインの導入 → `app/Plugin/`）。**複数ホストでは、それが起きたホストにしか
無い。** 別のホストに振られた人には「保存したのに変わらない」「ページが 500」になる（#100）。

対処は 2 つのどちらか:

1. **共有ストレージに載せる**（推奨）。アップロード画像と同じ NFS / EFS に `app/template`、
   `html/user_data`、`app/Plugin` も置き、全ホストで同じものを bind mount する。プラグインの
   有効化はキャッシュの組み立て直しを伴うので、その後に各ホストで `bin/plugin.sh reload`
2. **管理画面を 1 台に固定する**。LB で `/admin` をホスト 1 台にだけ振り（sticky ではなく固定）、
   そこで書いたものを `bin/pull-admin-files.sh` → git → `bin/deploy.sh` で他へ配る。
   手順が増えるが、共有ストレージが無い環境でも成り立つ

どちらも取らないなら、複数ホストでは管理画面からファイルを書く操作をしない
（テンプレートは git で、`docs/customize.md`）。

## バックアップは 1 台で

DB が外部になっても `bin/backup.sh` はそのまま使える（`db` サービスが無ければ `.env` の `DB_*` で
外部 DB に繋ぐ）。**複数ホストのうち 1 台だけ**で cron を回し、`BACKUP_SYNC` で外へ送る。
全ホストで回すと同じダンプが台数分できるだけ。

## 手順

1. **共有サービスを用意**（別ホスト or マネージド）: DB、Redis（キャッシュ）、Redis
   （セッション）、アップロード用 NFS/EFS。
2. **各アプリホスト**で `compose.app.yaml`（db/redis を含まない app 層のみ）を起動:
   ```bash
   docker compose -f compose.app.yaml up -d   # .env の ECCUBE_IMAGE で配布イメージを指定して pull（build しない）
   ```
   `.env` に外部エンドポイント（`DB_HOST` / `REDIS_URL` / `SESSION_REDIS_URL`）と
   `TRUSTED_PROXIES=<LB の IP/サブネット>` を設定する。
3. **スキーマ移行は 1 台だけ**: どこか 1 台を `ECCUBE_SKIP_DB_INIT=0` で起動して
   `migrate` を済ませ、以降の app ホストは `ECCUBE_SKIP_DB_INIT=1`（既定）で起動する
   （全台が一斉に migrate すると競合するため）。
4. **前段の LB**:
   - 自前 nginx: `docker/nginx/lb.conf.example` を参照（`upstream` に各 app ホストを列挙）。
   - Cloudflare Load Balancing: 各 app ホスト（の nginx:80/443）をオリジンプールに登録。
   - AWS ALB: ターゲットグループに各 app ホストを登録。ヘルスチェックは `/`。

> **重要**: LB で HTTPS を終端する場合、各アプリホストの `.env` に `TRUSTED_PROXIES` を
> 設定し、LB は `X-Forwarded-Proto` を送ること。これが無いと EC-CUBE が HTTPS を認識できず、
> セッション Cookie の `secure`/`SameSite=None` が付かず（決済で問題）、生成 URL も http に
> なる。セッションは Redis 共有なので **スティッキーセッションは不要**。

## デプロイ / 更新（CI とローリング更新）

**イメージは CI が 1 回だけ build** し、各ホストは pull する（全ホスト同一の保証）。

- `.github/workflows/build-image.yml`: main への push（`docker/php/**` 変更時）で
  `ghcr.io/<owner>/<repo>/ec-cube:latest` と `:<git-sha>` を push。手動実行では
  `ECCUBE_VERSION` を指定できる。認証は `GITHUB_TOKEN`（追加シークレット不要）。
- 各アプリホストの `.env` に `ECCUBE_IMAGE=ghcr.io/<owner>/<repo>/ec-cube:<sha>` を設定
  （`latest` より **sha 固定を推奨**。ロールバック = 前の sha に戻して pull）。

**ローリング更新**（無停止。1 台ずつ）:

```bash
# ホスト A で（他ホストは稼働継続）
# 1. LB からホスト A を外す（nginx LB: upstream をコメントアウトして reload /
#    Cloudflare LB: プールで無効化 / ALB: deregister）
# 2. 新イメージへ更新
docker compose -f compose.app.yaml pull ec-cube
docker compose -f compose.app.yaml up -d --no-build
# 3. ヘルス確認（healthy になるまで）
docker compose -f compose.app.yaml ps
curl -fsS http://localhost:8080/ -o /dev/null && echo OK
# 4. LB に戻す → 次のホストへ
```

- マイグレーションを伴う更新は、**先に 1 台（init ロール）で `ECCUBE_SKIP_DB_INIT=0`
  にして適用**してから残りを更新する（後方互換のあるスキーマ変更にすること）。
- 単一ホスト（compose.yaml）の場合はこの手順は使えず、`up -d --build` の数十秒の
  停止を許容するか、メンテナンス画面を挟む。

## さらに上（Tier 3）

- DB リードレプリカ（Doctrine の read/write 分割）、マネージド DB/Redis（RDS/Aurora・
  ElastiCache）、ECS/EKS/k8s + オートスケール、CloudFront/Cloudflare CDN。規模とコストに
  応じて設計する。

> フルページキャッシュ（nginx `fastcgi_cache`）は既定で無効。EC-CUBE はページに
> CSRF トークン・カート・ログイン状態を埋め込むため、誤配信の危険がある。有効化する
> 場合の雛形と注意は `docker/nginx/default.conf` 末尾のコメントを参照。

# メール送信の非同期化（Messenger）

**初回は無効。** `.env` の `COMPOSE_PROFILES` に `messenger` を足して `docker compose up -d`。
`worker` の起動と `app/config/eccube/optional/messenger/` の設定投入が同じ値で決まる。
**worker が居ないのに設定だけ入ると、メールは DB に溜まり続けて誰にも届かない**
（エラーは出ない）。同じスイッチにしてあるのはそのため。`bin/plugin.sh doctor` が
食い違いと未送信の件数を見る。

メールはキュー経由で送信される（Symfony Messenger + Doctrine transport）。

- **注文完了などのレスポンスが SMTP 応答を待たない**（同期送信だと外部 SMTP の
  遅延・障害が購入処理に直結する）。
- SMTP 停止中もメッセージは DB（`messenger_messages`）に残り、復旧後に送信される
  （5s→15s→45s で 3 回リトライ → `failed` キューへ）。
- consumer は `worker` サービス（`messenger:consume async`）。`--time-limit=3600` で
  定期再起動し、restart ポリシーで常駐。healthcheck（プロセス監視）つき。

運用コマンド:

```bash
docker compose logs -f worker                    # 送信ログ
docker compose exec worker runuser -u www-data -- php bin/console messenger:stats
docker compose exec worker runuser -u www-data -- php bin/console messenger:failed:show
docker compose exec worker runuser -u www-data -- php bin/console messenger:failed:retry
```

> 同期送信に戻すには `.env` の `COMPOSE_PROFILES` から `messenger` を外して `docker compose up -d`。
> Messenger 本体はイメージに焼いてある（`docker/php/Dockerfile`。本体ソースは非編集・再ビルドで再現）。

**テスト環境だけは同期送信に戻している**（`app/config/eccube/packages/test/messenger.yaml`）。
`messenger_async.yaml` には env 指定が無く test にも効いてしまうため、そのままだとテスト中の
メールがキューに積まれるだけで Symfony のテスト用 Transport に届かず、本体が持つ
`assertEmailCount()` 系のテストが軒並み「0 sent」で落ちる。

```yaml
framework:
    messenger:
        transports:
            async: 'sync://'   # ルーティング定義はそのまま、transport だけ同期に
```

---

[← README へ戻る](../README.md)
