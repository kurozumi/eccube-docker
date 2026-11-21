# 大規模アクセス / スケール

1台で捌く（Tier 1）→ 状態を外に出す（Tier 2）→ 複数ホスト、の順に進める。

**どこまで進めるかは、測ってから決める。** `bin/loadtest.sh` で何 PV/秒まで耐えるか・どこが先に詰まるかを
出せる（[負荷試験](loadtest.md)）。月間の PV から山の PV/秒を出す式もそちらにある。


段階的にスケールできる構成になっている（すべて実機検証済み・本体は非編集）:

| 段階 | 内容 | 節 |
|---|---|---|
| Tier 1 | 単一ホスト強化（php-fpm / OPcache / Redis キャッシュ / DB / nginx） | この節 |
| Tier 1 | 1台内の水平スケール（`--scale` 内部ロードバランス） | 水平スケール |
| Tier 2 | セッションの Redis 共有 | セッションの Redis 共有 |
| Tier 2 | アップロード画像の共有ストレージ（NFS/EFS） | アップロード画像 |
| Tier 2 | 複数ホスト + 外部 LB（`compose.app.yaml`） | 複数ホスト + LB |

## 打ち手は 3 つ（安くて効く順）

| | 打ち手 | 減るもの | いまの状態 |
|---|---|---|---|
| 1 | **CDN**（静的ファイルを中継点に持たせる） | 画像・CSS・JS のリクエスト。ページの 5〜10 倍の数がある | **Cloudflare のトンネルなら、もう効いている**（下の「CDN」で確かめ方） |
| 2 | **Redis のキャッシュ + アプリを並べる** | PHP の計算と、DB への同じ問い合わせ | 設定 1 行と台数で効く（下の「Redis とアプリを並べる」） |
| 3 | **DB を大きくする** | DB の負荷 | 遅い SQL を直し、Redis を入れても DB が詰まるとき（下の「3. DB が詰まったら」） |

負荷試験で先に詰まったのが PHP の CPU なら 2、DB なら 2 の Redis → 3、と進みます。1 はどちらでも先にやってよい（安い）。

**入れていないもの**: DB の読み取りを複製（リードレプリカ）へ振り分ける仕組みと、ページ（HTML）のキャッシュ。
どちらも EC-CUBE の作りのせいで、設定を足すだけでは効かないか、ほかの人のページを配ってしまいます（理由は下の「3」）。

## 1. CDN

### Cloudflare のトンネルで公開しているとき（既定）

**お客さんのリクエストはもう Cloudflare を通っているので、静的ファイルは中継点がキャッシュしています。**
Cloudflare は拡張子（CSS・JS・画像・フォントなど）で決め、元の `Cache-Control` に従って持ちます。
HTML はキャッシュしません（カート・ログイン状態・CSRF トークンが入るので、それで正しい）。

この環境が付けている `Cache-Control`（`docker/nginx/default.conf`・`docker/caddy/Caddyfile`）:

| もの | 持つ時間 | 理由 |
|---|---|---|
| 商品画像（`/html/upload/save_image/`） | 30 日 | 登録のたびに名前が変わる。同じ名前で中身は変わらない |
| CSS・JS・テーマの画像・フォント | 5 分 | **名前が変わらない。** EC-CUBE 4.2 / 4.3 は URL に版を付けず（4.4 も `user_data` だけ）、`customize.css` は管理画面の「CSS 管理」と deploy が同じ名前のまま書き換える。長く持たせると、直した CSS が中継点とブラウザに残る（v1.0.17 までは 30 日で、そうなっていた） |

5 分でも、中継点から元のサーバーに届くのは「中継点の数 × ファイルの数」が 5 分に 1 回だけです。

**Cloudflare の Browser Cache TTL を「Respect Existing Headers」にしておく**（Caching → Configuration）。
ここに 4 時間などの値が入っていると、Cloudflare は元の `max-age=300` をその値まで引き上げてブラウザへ渡し、
直した CSS がブラウザに何時間も残ります（商品画像の 30 日は元のほうが長いので、そのまま）。
下の確かめ方で、公開している名前から見た `cache-control` が `max-age=300` になっていれば大丈夫です。

**確かめ方**（2 回目で `HIT` になれば効いている）:

```bash
curl -sI https://shop.example.com/html/template/default/assets/css/style.css | grep -i -E 'cf-cache-status|cache-control'
curl -sI https://shop.example.com/html/template/default/assets/css/style.css | grep -i cf-cache-status   # HIT
```

**やってはいけないこと**: Cloudflare の Cache Rules で「Cache Everything（HTML もキャッシュ）」にしない。
ほかのお客さんのカート・ログイン状態・CSRF トークンが入ったページを配ってしまいます（下の「3」の「ページのキャッシュ」）。

すぐに反映したいとき（CSS を直してすぐ見せたい・テーマを入れ替えた）は、Cloudflare の画面の
Caching → Configuration → **Purge Cache**（URL を指定するか、全部）。5 分待てば、何もしなくても入れ替わります。

**Purge で消えるのは中継点の写しだけで、お客さんのブラウザの写しは消えません。** v1.0.17 以前（30 日）から
上げた直後は、それまでに来たお客さんのブラウザに古い CSS・JS が最長 30 日残ります。新しい `max-age` は、
ブラウザが次に取り直したときから効きます。すぐ全員に届けたいときは、そのファイルの URL を変えます
（読み込んでいる自分のテンプレートで `?v=2` を付ける、ファイル名を変える、など）。

### caddy で 80/443 を直接受けているとき

前に CDN がありません。足すなら、**トンネルに切り替えるのがいちばん簡単です**（`bin/setup.sh tunnel`。[本番デプロイ](deploy.md)の
「公開方式」。80/443 のポートも閉じられる）。DNS で Cloudflare のプロキシ（オレンジの雲）を前に置くこともできますが、
そうすると caddy から見たお客さんの IP が Cloudflare のものになり、ログインのレート制限やログが効かなくなります
（Cloudflare の IP 範囲を信じる設定が別に要る）。トンネルなら cloudflared が `X-Forwarded-For` を付け、nginx が
それを読むので、この問題がありません。

## 2. Redis とアプリを並べる

順番に。どれも、負荷試験（[負荷試験](loadtest.md)）で効いたかを比べながら進めます。

1. **Redis のキャッシュを入れる**: `.env` の `COMPOSE_PROFILES` に `redis` を足して `bin/deploy.sh`
   （例: `COMPOSE_PROFILES=tunnel,redis`）。Symfony のキャッシュと Doctrine のメタデータが Redis に載り、
   セッションも `redis-session` に移ります。**切り替えた瞬間、全員ログアウトになり、カートも消えます**
   （下の「セッションの Redis 共有」）。お客さんの少ない時間に。
2. **1 台の中で php-fpm を増やす**: まず `.env` の `PHP_FPM_MAX_CHILDREN` をメモリの範囲で上げる（1 本 80MB ほど）。
   **`.env` を直したら `bin/deploy.sh`**（ec-cube が作り直されて新しい値で立つ。`.env` を直しただけでは 20 のまま）。
   CPU に余裕があるのに php-fpm の上限（max_children）が出ているときに効きます。CPU が張り付いているなら、
   サーバーを大きくするか、次へ。
3. **ホストを並べる**: DB・Redis・画像を外に出し（マネージド DB・マネージド Redis・NFS / EFS）、各ホストで
   `compose.app.yaml` を動かし、前に LB を置きます（下の「複数ホスト + ロードバランサ」）。セッションは Redis に
   あるので、LB で同じ人を同じホストへ寄せる設定（スティッキーセッション）は要りません。
   **DB の接続数に気をつける**: 全ホストの `PHP_FPM_MAX_CHILDREN` の合計 + 余裕が、DB の `max_connections`
   （既定 200）を超えると「Too many connections」で落ちます（下の「単一ホスト強化」の式）。

1 台の中で ec-cube のコンテナを増やす（`--scale`）こともできますが、同じ CPU を分け合うだけなので、
2 の `PHP_FPM_MAX_CHILDREN` と効き目はほぼ同じです。やるなら、下の「水平スケール」の手順どおりに
（素の `--scale` だと、増えたコンテナの起動時の `cache:clear` が動いているほうのキャッシュを消し、500 を出します）。

## 3. DB が詰まったら

1. **遅い SQL を見る**: プラグインの 1 本の SQL が原因のことが多い。**設定ファイルを直しただけでは、動いている DB には
   効きません**（起動のときにしか読まない。`bin/deploy.sh` も DB は作り直さない）。その場で入れて確かめる（MariaDB）:

   ```bash
   docker compose exec db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -uroot -e "SET GLOBAL slow_query_log = 1; SHOW GLOBAL VARIABLES LIKE \"slow_query_log%\""'
   ```

   1 秒（`long_query_time`）を超えた SQL が、データディレクトリの中の `slow_query_log_file` に溜まります。
   次の起動からも続けるなら `docker/mariadb/conf.d/eccube.cnf` の `slow_query_log = 1` も直す（DB の再起動で効く。
   数秒止まる）。調べ終わったら `SET GLOBAL slow_query_log = 0` で戻す
2. **Redis のキャッシュ**（上の 2 の 1）。Doctrine のメタデータと結果のキャッシュが Redis に載る
3. **DB そのものを大きくする**: マネージド DB（RDS・Aurora など）へ出して、上の型へ上げる（下の「複数ホスト + LB」）

### 入れていないもの（理由）

**DB の読み取りの振り分け（リードレプリカ）は、設定だけでは効きません。** EC-CUBE 本体（4.2 / 4.3 / 4.4）は、
リクエストのたびに最初にトランザクションを始めます（`Eccube\EventListener\TransactionListener`）。Doctrine の
primary / replica の接続は、トランザクションが始まった時点で primary に切り替わってそのままなので、複製は一度も
使われません。効かせるには本体のこの動きを差し替える必要があり、閲覧中に書き込むプラグインが「例外が出たら全部
取り消す」保証を失います。さらに、書いた直後のページ（カートに入れた直後のカートなど）を複製から読むと、追いついて
いない古い値が出ます。手元の負荷試験で先に詰まったのは PHP で（ec-cube が CPU 約 10 コア分、DB は 1.5 コア分）、
DB を軽くしても速くならない状態でした。**本番と同じ形で測って DB が先に詰まり、上の 1〜3 でも足りないと分かってから**
考えます。

**ページ（HTML）のキャッシュは、そのままでは配れません。** いちばん見られる商品一覧と商品詳細には、
「カートに入れる」のフォームに人ごとの CSRF トークンが入っています（`form_rest(form)`）。ヘッダーのカートの件数と
ログインの欄も人ごとです。キャッシュすると、ほかの人のカートの件数が見え、トークンが合わないので「カートに入れる」が
失敗します。やるなら、人ごとの部分を JavaScript であとから取る形にテーマを直す必要があり、直すのは店ごとのテーマなので、
プラグインとの相性も 1 本ずつ確かめることになります。`docker/nginx/default.conf` の末尾のコメントは、その前提での雛形です。

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

- セッションのハンドラを `Customize\Session\RawRedisSessionHandler` に差し替える
  （`app/config/eccube/optional/redis/redis_session.yaml` の `framework.session.handler_id`）。
  **EC-CUBE 4.2 / 4.3 では、本体の `SameSiteNoneCompatSessionHandler` で包み直す**
  （`app/config/eccube/packages/redis_session_samesite.php`）。Cookie の SameSite=None・Secure・パスは
  あのハンドラが付けているので、包まないと SameSite がブラウザの既定（Lax）になり、決済の戻り
  （よそのサイトからの POST）でセッションが届かない。4.4 にはこのクラスが無く、本体の framework.yaml が
  `cookie_secure: auto` と `cookie_samesite: none` を書いている（Redis にしてもそのまま効く）。
- 接続先は `.env` の `SESSION_REDIS_URL`（本番はマネージド Redis に向けられる）。
- キャッシュ用 `redis`（`allkeys-lru`）とは別インスタンスにして、セッションが LRU で
  勝手に消えないようにしている。上限は `.env` の `SESSION_REDIS_MAXMEMORY`（既定 256mb）。
  到達時は OOM ではなく新規セッションの書込エラーになり、既存ユーザーは守られる。
- 単一ホストのみで運用するなら不要。`.env` の `COMPOSE_PROFILES` から `redis` を外せば、
  entrypoint が設定を外してファイルのセッションに戻る（`redis-session` も立たない）。

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

**1 台で足りるうちは 1 台で。** 複数台にすると、更新・バックアップ・管理画面の運用がどれも手間になる。
`bin/loadtest.sh` で測って、1 台の中の手（php-fpm の枠、Redis、CDN）を打っても PHP が詰まるときに
使う（`docs/loadtest.md`）。

アプリ層はステートレスにできる（セッションとキャッシュ = Redis、画像 = 共有ストレージ、DB = 外部）ので、
**アプリホストを N 台並べて前段に LB** を置ける。

## 構成

```
                   お客さん（HTTPS）
                        │
            ┌─ LB（HTTPS 終端。自前 nginx・Cloudflare LB・ALB）
            │        │ 振り分け（スティッキー不要）
   ┌────────┴──┐  ┌──┴────────┐
   │ app host1 │  │ app host2 │  … 各ホストで compose.app.yaml（ec-cube + nginx + worker）
   │ init 役   │  │           │     host1 だけが migration を流す（ECCUBE_SKIP_DB_INIT=0）
   └────┬──────┘  └────┬──────┘
        └──────┬───────┘  すべて同じ外部サービスを見る
   共有: DB / Redis（キャッシュ）/ Redis（セッション）/ 画像（NFS・EFS）
```

## 始める前に決めること

| 決めること | 選びかた |
|---|---|
| DB | マネージド DB（RDS・Cloud SQL など）か、別のサーバー。全ホストが同じものを見る |
| Redis 2 つ | キャッシュ用とセッション用を**別々に**（セッションが LRU で消えないように）。マネージド Redis でよい |
| 画像の置き場 | NFS か EFS。ローカルのボリュームのままだと、ホストごとに別の画像になる |
| init 役のホスト | migration を流す 1 台。ほかは流さない（全台が一斉に流すと競合する） |
| 管理画面が書くファイル | 共有ストレージに載せるか、管理画面を 1 台に固定するか（下の「管理画面が書くファイル」） |
| イメージのタグ | **日付タグで全ホストを揃える**（`4.3-php8.3-20261123` のような形。月曜の日付は全部の組にある）。追跡タグ（`4.3`）だと、ホストごとに引いた日の中身になる |

## 手順

### 1. まず 1 台で店を作る

いつもどおり 1 台で店を立て（`docs/install.md`）、本番構成で動くところまで持っていく。
**アプリホストの上では新しく店を作れない**（`compose.app.yaml` は `html/user_data` を読み取り専用で
mount するので、インストールが初期ファイルを置けずに止まる）。

### 2. 共有サービスへ移す（1 台目で）

1. **DB**: `bin/setup.sh db` で外部 DB へ写して切り替える（写す先に店があれば止まる。写している間は
   メンテナンス表示）。
2. **Redis**: `.env` の `COMPOSE_PROFILES` に `redis` を入れ、`REDIS_URL` と `SESSION_REDIS_URL` を
   共有の Redis 2 つへ向けて `docker compose up -d`。**この瞬間に全員ログアウトになる**ので時間を選ぶ。
3. **画像**: いまの画像を退避してから（`bin/backup.sh`）、`eccube_upload` を NFS / EFS のボリュームに
   差し替えて中身を写す（下の「アップロード画像の共有ストレージ」）。

ここで一度 `bin/plugin.sh doctor` と画面で確かめる。1 台のまま、共有サービスで動く状態になっていればよい。

### 3. アプリホストを用意する（各ホストで）

コードは `bin/bootstrap-server.sh <host>:<path>` で送るか、店のリポジトリを clone する。
`.env` は **1 台目のものを写してから**、ホストごとに直す。

| キー | 値 | なぜ |
|---|---|---|
| `ECCUBE_AUTH_MAGIC` | **1 台目と同じ**（写したまま） | 全パスワードのハッシュの鍵。違うとそのホストでは誰もログインできない |
| `DB_*` / `REDIS_URL` / `SESSION_REDIS_URL` | 共有サービス（写したまま） | |
| `COMPOSE_FILE` | `compose.app.yaml` | DB と Redis を手元に立てない。`bin/*.sh` もこれを見て本番として扱う |
| `COMPOSE_PROJECT_NAME` | 全ホストで同じ名前（例 `myshop`） | ボリューム名とバックアップの名前が揃う |
| `ECCUBE_IMAGE` | 日付タグ（全ホスト同じ） | 全ホストで同じ中身にする |
| `ECCUBE_SKIP_DB_INIT` | init 役は `0`、ほかは書かない（既定 `1`） | migration を流すのは 1 台だけ |
| `HTTP_BIND` | **必須。** そのホストのプライベート IP（例 `10.0.0.11`） | 公開 IP にも開くと、LB を通らずに直接届き、`X-Forwarded-For` で IP を詐称できる（無いと起動しない） |
| `HTTP_PORT` | 既定 `8080` のままでよい | LB からはこのポートへ振る |
| `TRUSTED_PROXIES` | **書かない**（既定 `REMOTE_ADDR`） | 下の「HTTPS の判定」 |

**v1.0.19 までの配布イメージでは、DB に店がある状態で新しいホスト（新しいボリューム）を
`ECCUBE_SKIP_DB_INIT=0` で起動すると、`eccube:install` が共有の DB の表を全部消して作り直す。**
v1.0.20 からは、起動時に DB に店（`dtb_base_info`）があれば install せずに migration へ回る
（繋がらなくて確かめられないときも install しない）。古いイメージのままなら、init 役は
最初にデータを入れた 1 台から動かさないこと。

PostgreSQL のときは、さらに `DB_ENGINE=postgresql`・`DB_PORT=5432`・`DATABASE_SERVER_VERSION=16`
（実物の版）・`DB_CHARSET=utf8` を書く（1 台構成では `compose.postgresql.yaml` が足していたもの）。

起動して確かめる:

```bash
docker compose pull
docker compose up -d
bin/healthcheck.sh          # このホストの nginx に直接聞く
bin/plugin.sh doctor        # Redis は「外部」と出れば正しい
```

`messenger`（メールの非同期送信）を使っているなら、`COMPOSE_PROFILES` に `messenger` が入っていれば
各ホストで `worker` も立つ。

### 4. LB を置く

- **自前の nginx**: `docker/nginx/lb.conf.example`。`upstream` に各ホストの `<プライベート IP>:8080` を並べる。
- **Cloudflare Load Balancing / AWS ALB**: 各ホストの `:8080` をオリジン（ターゲット）に登録する。
- **ヘルスチェックは `/`。ただし、何を「正常」とするかに気をつける。** LB のヘルスチェックは
  `X-Forwarded-Proto` を付けず、`Host` はホストの IP になる。**`ECCUBE_FORCE_SSL` の店は `/` に 301 を返し、
  `TRUSTED_HOSTS` を書いた店は 400 を返す。** 200 だけを正常にすると全部のホストが外れ、サイトが落ちる。
  - Cloudflare（モニターにヘッダーを足せる）: `Host: <店のドメイン>` と `X-Forwarded-Proto: https` を付け、200 を正常にする。
  - ALB（ヘッダーを足せない）: 正常のコードを `200-399` にする（`TRUSTED_HOSTS` を書いているなら、その中に
    ホストの IP も足す）。これは「nginx と PHP が返事をする」までしか見ないので、画面が組み立つかは
    `bin/healthcheck.sh`（各ホストで）と `deploy.sh` の最後の確かめで見る。
- **スティッキーセッションは要らない**（セッションは Redis で共有）。
- LB は `X-Forwarded-Proto` と `X-Forwarded-For` を付けて送る（ALB・Cloudflare は自分で付ける）。

### 5. 確かめる

- 何度か開いて、両方のホストのログ（`docker compose logs nginx`）に届いていること。
- ログインして別のページへ移っても、ログインが切れないこと（セッションの共有）。
- ブラウザの開発者ツールで、Cookie `eccube` に `Secure` が付いていること（HTTPS の判定）。
- 管理画面で商品画像を入れ、別のホストに振られても表示されること（画像の共有）。

## HTTPS の判定（TRUSTED_PROXIES）

**既定の `REMOTE_ADDR` のままにする。** 各ホストの nginx が `X-Forwarded-For` から本当のお客さんの IP を
取り出して EC-CUBE に渡すので、EC-CUBE から見た直前の相手は「LB」ではなく「お客さん」になる。
LB のサブネット（`10.0.0.0/8` など）を書くと、お客さんの IP がその中に無いので信頼されず、
**HTTPS と判定されない**（Cookie に `Secure` が付かない、生成する URL が `http://` になる、決済の
戻りで弾かれる）。以前の案内はサブネットを書かせていて、2 台で試してこれを確かめた。

そのぶん、**nginx に LB 以外から届かないこと**が前提になる。nginx は `X-Forwarded-For` の右端（直前の LB が
付けた値）をお客さんの IP として使うので、直接届くとその値を偽れて、管理画面の IP 制限とログインの回数制限が
抜ける。`HTTP_BIND` をプライベート IP にし（必須）、`8080` を LB にだけ開ける。**開ける・閉じるはクラウドの
セキュリティグループ（または `DOCKER-USER` チェーン）で。** Docker が公開したポートは ufw / INPUT の規則より
先に通るので、ufw で閉じたつもりでも同じネットワークのほかのマシンから届く。

**LB の前にさらに CDN を置くとき**（Cloudflare のプロキシ〔オレンジの雲〕→ ALB、など）、右端の値は CDN の
中継点の IP になる。**お客さんが中継点ごとにまとまり**、ログインの回数制限がよその人まで巻き込み、管理画面の
IP 制限も効かなくなる。そのときは `docker/nginx/default.conf` の `real_ip_header` を `CF-Connecting-IP` に
する（Cloudflare）か、`set_real_ip_from` を LB と CDN の範囲に絞って `real_ip_recursive on` にする。

## 管理画面が書くファイルは 1 台にしか無い

管理画面は DB だけでなくファイルにも書く（ページ管理 → `app/template/user_data/`、ブロック管理 →
`app/template/<テーマ>/Block/`、CSS・JS 管理 → `html/user_data/assets/`、ファイル管理 →
`html/user_data/`、プラグインの導入 → `app/Plugin/`）。**複数ホストでは、それが起きたホストにしか
無い。** 別のホストに振られた人には「保存したのに変わらない」「ページが 500」になる（#100）。
アプリホストでは `app/Plugin` と `html/user_data` を読み取り専用で mount しているので、プラグインの
導入とファイル管理はそもそも失敗する。

対処は 2 つのどちらか:

1. **共有ストレージに載せる**。アップロード画像と同じ NFS / EFS に `app/template`、
   `html/user_data`、`app/Plugin` も置き、全ホストで同じものを bind mount する。プラグインの
   有効化はキャッシュの組み立て直しを伴うので、その後に各ホストで `bin/plugin.sh reload`
2. **管理画面を 1 台に固定する**（共有ストレージが無いとき）。LB で `/<管理画面のパス>` を init 役のホストに
   だけ振り、そこで書いたものを `bin/pull-admin-files.sh` → git → 各ホストで `bin/deploy.sh` で配る

どちらも取らないなら、複数ホストでは管理画面からファイルを書く操作をしない
（テンプレートは git で、`docs/customize.md`）。

## 運用

### 毎日のコードの反映（ローリング）

1 台ずつ、LB から外して反映し、戻す。**migration を含むときは init 役から。**

```bash
# 1. LB からこのホストを外す（nginx: upstream の行に down を付けて reload / Cloudflare: プールで無効 / ALB: deregister）
# 2. 反映する（本番なのでプロジェクト名を打たせる。非対話は CONFIRM_DEPLOY=<名前>）
bin/deploy.sh
# 3. 開くことを確かめる（deploy.sh も最後に確かめる）
bin/healthcheck.sh
# 4. LB に戻して、次のホストへ
```

- `deploy.sh` は外部 DB のバックアップも取る。**全ホストで取ると同じものが台数分できる**ので、
  2 台目以降は `bin/deploy.sh --no-backup` でよい（init 役で取った直後なら）。
- migration は**古いコードでも壊れない形**（列を足すだけ、など）にする。init 役で流したあと、残りの
  ホストが新しいコードになるまでの間、古いコードが新しいスキーマで動く。
- **エンティティやプラグインが変わる反映は、1 台ずつではなく全部を止めて行う**（下の「EC-CUBE を上げる」と
  同じ順）。Doctrine のメタデータは共有のキャッシュの Redis に載るので、新しいホストが書いたものを古い
  ホストが読み、`Unrecognized field` / `Property ... does not exist` で落ちる（最後のホストの反映が
  キャッシュを消すまで）。

### PHP と Debian のパッチ（イメージの更新）

日付タグで固定しているので、**自動では変わらない。** 週に一度（月曜の焼き直しのあと）、全ホストの
`.env` の `ECCUBE_IMAGE` を新しい日付タグに書き換え、上の手順で 1 台ずつ `bin/deploy.sh`。
急ぎの脆弱性（`security-scan` の Issue）は、その日の日付タグで同じことをする。

### EC-CUBE を上げる（`bin/upgrade.sh`）

**全ホストを止める時間が要る。** 版の違う本体がキャッシュの Redis を共有すると、片方が書いたものを
もう片方が読んで壊れる。

1. LB を「メンテナンス中」にする（自前 nginx なら `return 503`。Cloudflare / ALB は固定の応答）
2. init 役**以外**のホストを止める: `docker compose stop ec-cube`（`messenger` を使っていれば `worker` も）
3. init 役で `bin/self-update.sh` → `bin/upgrade.sh <制約>`（外部 DB の退避・失敗したら自動で戻す、は
   1 台のときと同じ）。終わったら新しい日付タグを `.env` に控える
4. 残りのホストで、`bin/self-update.sh`（init 役と同じ版にそろえる）→ `.env` の `ECCUBE_IMAGE` を同じタグに
   して `bin/upgrade.sh <制約>`（スキーマには触らない）
5. LB を戻す

キャッシュの Redis は `upgrade.sh` が新しい版を起動する前に空にする（`cache:pool:clear --all`。セッションの
Redis は別なので消えない）。前の版が書いたものを新しい版が読まないためで、ほかのホストを止めてあるのが前提。

### バックアップは 1 台で

DB が外部になっても `bin/backup.sh` はそのまま使える（`db` サービスが無ければ `.env` の `DB_*` で
外部 DB に繋ぐ）。**init 役の 1 台だけ**で cron を回し、`BACKUP_SYNC` で外へ送る。
全ホストで回すと同じダンプが台数分できるだけ。画像は NFS / EFS 側でも別に取っておく。

### ホストを足す・外す

- **足す**: 手順 3 で用意し（`ECCUBE_SKIP_DB_INIT` は書かない）、確かめてから LB に入れる。
- **外す**: LB から外してから `docker compose down`（`-v` は付けない）。

## DB を外に出す（マネージド DB）

**`bin/setup.sh db`** で切り替える（繋がるか試す → いまのデータを写すか聞く → `.env` と `COMPOSE_FILE`
を書き換えて起動し直す）。手元の `db` は止まるがボリュームは残る。`bin/backup.sh` / `restore.sh` は
`.env` の `DB_*` を見て外部 DB に繋ぐので、そのまま使える。

写すときは:
- **写す先にもう店があれば止まり、データベース名を打たせる。** 打てば、写す前にその DB の中身を
  `backups/<日時>-setup-db-target/` へ取ってから上書きする（向き先の取り違えで別の店の DB を消さない）。
- **写している間はメンテナンス表示。** 切り替えて起動し直したあとに外す（写してから切り替えるまでの注文が、
  古い DB にだけ残って新しい店から消える、を防ぐ）。
- PostgreSQL は 1 つのトランザクションで流し、エラーで止める。写せなければ `.env` は変えない。

## ネットワークと権限

- `frontend`（公開層と nginx）と `backend`（nginx・アプリ・DB・Redis）の 2 つ。公開層
  （cloudflared / caddy）から DB や Redis には直接届かない。`docker run` で DB に繋ぐときは
  `--network <project>_backend`（`bin/backup.sh` がそうしている）
- 全コンテナが `no-new-privileges` と `cap_drop: ALL`。要るものだけ `cap_add`。新しいサービスを
  足したら `<<: *hardened` と `networks:` を書く（compose.yaml のコメント参照）
- Redis は `REDIS_PASSWORD` で認証（`bin/init.sh` が生成して URL に埋める）。古い `.env` で空なら
  認証なしのまま動く。足すなら `.env` に `REDIS_PASSWORD` を書き、`REDIS_URL` /
  `SESSION_REDIS_URL` を `redis://:<pass>@redis:6379` の形にして `docker compose up -d`
  （**全員ログアウトになる**）

## さらに上（Tier 3）

- マネージド DB/Redis（RDS/Aurora・ElastiCache）、ECS/EKS/k8s + オートスケール。規模とコストに
  応じて設計する。CDN は上の「1. CDN」。DB リードレプリカは、本体がリクエストごとにトランザクションを
  張るので設定だけでは効かない（上の「3」）。

> フルページキャッシュ（nginx `fastcgi_cache`）は既定で無効。EC-CUBE はページに
> CSRF トークン・カート・ログイン状態を埋め込むため、誤配信の危険がある（上の「3」）。
> 雛形と注意は `docker/nginx/default.conf` 末尾のコメント。

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
