# バージョン切替 / バージョンアップ

運用中の店舗を上げる手順と、開発で別バージョンを試す手順。**本番では `--prod` を付ける。**


用途が違う 2 本がある。**運用中の店舗を上げるなら `upgrade.sh`**。

```bash
bin/upgrade.sh ~4.3.2          # データを保ったまま上げる（運用中の環境向け）
bin/switch-version.sh ~4.2.0   # データごと作り直す（開発で別バージョンを試す用）
```

|                    | DB・アップロード画像 | 用途                     |
| ------------------ | -------------------- | ------------------------ |
| `upgrade.sh`       | **残る**             | 運用中の環境を上げる     |
| `switch-version.sh` | 破棄される（`down -v`） | 開発で別バージョンを試す |

`switch-version.sh` は「指定バージョンをまっさらに立て直す」ツールで、バージョンアップ
ツールではない。**本番環境に使うと受注・会員データが消える。**

どちらも**破棄はビルドが通ってから行う**。先に `down -v` すると、新バージョンの取得や
依存解決に失敗したときにデータだけ消えて環境が残らない。ビルドが失敗した場合は `.env` の
`ECCUBE_VERSION` を元へ戻して終了し、稼働中の環境とデータには触れない。

## バージョンアップの手順

**本番でいきなり実行しない。** 本番のデータを写したステージングで一度通し、出たエラーを
潰してから本番に入る。`bin/upgrade.sh` は危険を検出すると止まるが、「止まらずに済む状態」
にする作業はステージングでやる。

### 1. 事前確認

```bash
# いま動いている Symfony の世代（プラグイン互換性の判断材料）
docker compose exec ec-cube runuser -u www-data -- composer show symfony/framework-bundle

# 入っているプラグインの一覧
bin/plugin.sh list
```

- **プラグインの対応状況**を先に調べる（下の「プラグインの互換性」）。ここが一番詰まる
- **PHP のバージョン要件**を確認する。`bin/upgrade.sh` は `ECCUBE_VERSION` しか書き換え
  ないので、PHP を上げる必要があるなら `.env` の `PHP_VERSION` を手で変える
- **バックアップの保存先**がサーバー外にあるか確認する

### 2. ステージングで予行演習

```bash
# 別ディレクトリに clone し、プロジェクト名とポートを分ける
git clone <this-repo> eccube-staging && cd eccube-staging
cp ../eccube-docker/.env .
#   .env を編集: COMPOSE_PROJECT_NAME=eccube-staging / HTTP_PORT=8090
bin/init.sh

# 本番のバックアップを流し込む（本物のデータで試すのが肝心）
bin/restore.sh ../eccube-docker/backups/<日時>

# 本番と同じプラグインを app/Plugin へ置いてから実行
bin/upgrade.sh ~4.4.0
```

エラーが出たら `app/Customize` / `app/template` / プラグインを直し、**ステージングを作り
直して最初から通す**。「通ったところから再開」だと直し漏れに気づけない。

### 3. 本番で実施

```bash
# 告知してから（ダウンタイムが発生する）
bin/backup.sh                    # upgrade.sh も取るが、外部保管ぶんを手元にも
bin/upgrade.sh ~4.4.0 --prod     # 本番構成（compose.prod.yaml）で上げ直す
```

**`--prod` を付ける。** 付けないと `compose.override.yaml`（開発用のポートと
bind mount）が効いた状態で公開されてしまう。**画面は出るので気づきにくい。**

稼働中のスタックが本番構成なら、`--prod` を付け忘れても自動でそちらに寄せる
（コンテナに残っている compose の設定ファイル一覧を見ている）。ただし
**付ける前提で手順を書くこと。** 停止中に打つと自動判定は効かない。

完了後、最低でもこれだけは目視で確認する。

- フロントの表示・商品詳細・カート投入
- 管理画面のログイン・受注一覧・商品登録
- 決済まわり（決済プラグインを使っているなら特に）
- `docker compose logs ec-cube` にエラーが出ていないか

### 4. 失敗したとき

`bin/upgrade.sh` は失敗した段階によって止まる場所が違う。

| 止まった場所 | 状態 | 対処 |
| ------------ | ---- | ---- |
| ビルド / 事前確認 | **稼働中の環境は無傷** | プラグインを直して再実行 |
| スキーマ差分の検査 | サイト停止・**DB は無傷** | 差分を確認し、原因のプラグインを直す |
| `schema:update` / `migrate` | サイト停止・DB は途中まで適用 | `bin/upgrade.sh <旧バージョン>` で戻し、必要なら `bin/restore.sh` |
| 起動確認 | 公開済みだが応答しない | ログを見る。だめなら上と同じ |

切り戻しは `.env` を戻すだけでは足りない。**本体コードを戻すために `bin/upgrade.sh <旧
バージョン>` を実行**し、DB を戻すなら `bin/restore.sh <バックアップ>` も要る。

## プラグインの互換性

**EC-CUBE のマイナーバージョンアップは、土台の Symfony の世代交代を伴うことがある。**
その場合、プラグインが継承しているクラスのシグネチャや、使っている Symfony の API が
変わるため、**旧バージョン向けのプラグインはそのままでは動かない**。

このリポジトリで実測した対応:

| EC-CUBE | Symfony | 備考 |
| ------- | ------- | ---- |
| 4.2 系 | 5.4 | 実測 |
| 4.3 系 | 6.4 | 実測 |
| 4.4 系 | **7.4** | 実測 |

> 4.5 以降は未確認。上のコマンドで実際の値を見ること。**世代が変わっていれば
> プラグインの改修が要ると考えてよい。** 4.3 → 4.4 では 6.4 → 7.4 と 2 世代
> 進んでいる。

実際に 4.2 向けプラグインを 4.3 に載せると、こうなる（EC-CUBE 同梱のサンプル
プラグインで再現したもの）。

```
Fatal error: Declaration of Plugin\MigrationSample\PluginManager::install(
  array $meta, Symfony\Component\DependencyInjection\ContainerInterface $container
) must be compatible with Eccube\Plugin\AbstractPluginManager::install(
  array $meta, Psr\Container\ContainerInterface $container
)
```

4.3 で `AbstractPluginManager::install()` の型が `Symfony\...\ContainerInterface` から
`Psr\Container\ContainerInterface` に変わったため。**クラス宣言の互換性チェックで落ちる
ので、`bin/console` を使う処理はすべて巻き添えになる。**

`bin/upgrade.sh` はこれを **ビルド直後・`down` の前** に検出して中止する。新イメージと
ホストの `app/Plugin` / `app/Customize` だけでコンテナを起動し、クラスが読めるか試す。
止まった時点で稼働中の環境・DB・画像には一切触れていない。

対処:

| プラグインの出どころ | やること |
| -------------------- | -------- |
| オーナーズストア | 新バージョン対応版が出ているか確認する。無ければ**出るまでバージョンアップしない**か、代替を探す |
| 自作 | 自分で改修する。シグネチャ変更・非推奨 API の置き換えが中心 |
| もう使っていない | 無効化して外す（下記） |

使っていないプラグインを外す手順:

```bash
docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:disable --code=Foo
docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:uninstall --code=Foo
rm -rf app/Plugin/Foo
```

> **無効化しただけで列が残っていると `bin/upgrade.sh` が止まる。** プラグインが
> `EntityExtension` で足した列は、プラグインが無効だとエンティティ定義から消えるため
> `schema:update` の削除対象になるため。止まった場合は差分 SQL を見て、その列が本当に
> 不要か判断してから手で削除する。

## マイナーバージョンが出たときの段取り

**パッチ（4.4.1 → 4.4.2）とマイナー（4.4 → 4.5）で作業量がまったく違う。**
まずどちらかを見分ける。

| | 例 | プラグイン | 手順 |
| --- | --- | --- | --- |
| **パッチ** | 4.4.1 → 4.4.2 | そのままでよい | `bin/upgrade.sh ~4.4.2 --prod` だけ |
| **マイナー** | 4.4 → 4.5 | **全数の移植が要る** | 以下 |

### 1. 影響を調べる

```bash
docker compose exec ec-cube runuser -u www-data -- composer show symfony/framework-bundle
```

Symfony の世代が上がっていれば改修が要る（上の表）。

### 2. プラグインの新ブランチを切る

**対象 EC-CUBE 版ごとに保守ブランチを持つ**規則になっている。直前の版の
ブランチから切り、コード名・composer パッケージ名・`composer.json` の
`version` を一括で置換する。

| ブランチ | code | package |
| --- | --- | --- |
| `4.4` | `ProductSort44` | `ec-cube/productsort44` |
| `4.5` | `ProductSort45` | `ec-cube/productsort45` |

**CI の matrix も足すこと。**

```yaml
# .github/workflows/test.yaml
matrix:
  eccube-versions: [ '4.5' ]
```

いまは全プラグインが `4.4` 固定なので、**足さないと新版で一度も検証されない。**

### 3. 移植する

**このコードベースで黙って壊れる型が 3 つある。** どれも例外が出ないので、
移植のときはここを重点的に見る。

| 壊れ方 | 何が起きるか | 例 |
| --- | --- | --- |
| **目印による差し込み** | 本体が class やコメントを変えると**差し込みが消える。画面は 200 で返る** | 受注詳細の `<!-- ショップ用メモ欄 -->`、注文履歴の `.ec-orderRole__detail`、カートの `.ec-cartRole__actions` |
| **本体の処理への割り込み** | 本体が優先度や処理順を変えると**金額や判定が変わる。例外は出ない** | 見積は本体の `PriceChangeValidator`（priority 800）の前後で単価を入れ替えている |
| **本体の副作用への対処** | 本体が直せば不要になり、変えれば効かなくなる | 資格の「カートに入れる前に止める」、テンプレート編集の「テーマへ書かれた写しを消す」「`deletable` を戻す」 |

差し込みが消えたことはテストで気づけない（**目印が無ければ黙って何もしない**
作りにしてあるため）。**画面を開いて目で見ること。**

### 4. ステージングで通す → 5. 本番

上の「[バージョンアップの手順](#バージョンアップの手順)」と同じ。本番は
`bin/upgrade.sh ~4.5.0 --prod`。

## プラグインのデータは残るか

| 対象 | `bin/upgrade.sh` 後 |
| ---- | ------------------- |
| プラグイン独自テーブル（`plg_xxx`） | **残る** |
| `dtb_plugin` の有効状態・バージョン | **残る** |
| `app/Plugin/<Code>` のファイル | **残る**（bind-mount のため） |
| `EntityExtension` で足した列 | プラグインが**有効なら残る**。無効・非対応だと削除対象（検出して中止する） |
| ストア製プラグインの `composer.json` / `vendor/` | **消える**（`eccube_app` 側にあるため） |

最後の行が要注意。オーナーズストア経由のインストールは `composer require ec-cube/<code>`
を実行するため、composer の管理状態が `eccube_app` ボリュームに載る。**依存パッケージを
持つストア製プラグインは、バージョンアップ後に管理画面から入れ直す**こと。プラグイン本体
のファイルと DB のデータは残っているので、再インストールで元に戻る。

## bin/upgrade.sh の動き

1. `bin/backup.sh` を実行（失敗したら何も触らずに中止）
2. `.env` の `ECCUBE_VERSION` を更新してイメージをビルド（ビルド失敗時は `.env` を戻す）
3. `docker compose down`（`-v` なし）→ **`eccube_app` ボリュームだけ** 削除
4. 起動前に `var/.eccube_installed` を置く
5. **公開しないまま** DB を整合させる（`compose run` の使い捨てコンテナ。nginx は上げない）
   1. `doctrine:schema:update` — 差分 SQL を表示してから適用（DDL）
   2. `doctrine:migrations:migrate` — 本体 18 件のデータ移行
6. `up -d` で公開

手順 3 が要る理由は、`eccube_app` が `/var/www/html` 全体を覆っているため、イメージを
作り直しても既存ボリュームがある限り新しい本体コードが反映されないから
（`docker/php/docker-entrypoint.sh` の `1b)` のコメント参照）。

手順 4 が要る理由は、`eccube_app` を作り直すとマーカーが消え、entrypoint が「未インストール」と
誤判定して**データの入った既存 DB に `eccube:install` を撃ってしまう**ため。先にマーカーを
置くことで migration 経路へ寄せる。

手順 5 を**公開前**にやるのは、先に `up -d` すると新コードと旧スキーマが噛み合わない状態で
nginx が公開され、スキーマ更新が終わるまで全ページ 500 を返すため。`compose run` の
使い捨てコンテナは `ec-cube` の `depends_on`（db / redis / redis-session）しか連れて
こないので、nginx と worker を上げずに DB だけ整合させられる。

> それでも `down` から `up -d` までの**ダウンタイムそのものは無くならない**（接続断に
> なる）。無停止にしたいなら別系統を立てて LB で切り替える構成が要る。

手順 5 が 2 つに分かれているのは、**EC-CUBE 4.x のバージョンアップが 2 段構え**だから。

| 対象 | 正となるもの | 手段 |
| ---- | ------------ | ---- |
| DDL（カラム追加など） | エンティティ定義 | `doctrine:schema:update` |
| データ（マスタ追加・不整合の是正） | `app/DoctrineMigrations` の migration | `doctrine:migrations:migrate` |

本体の migration 18 件には `ALTER TABLE` / `CREATE TABLE` が **1 件も無い**（全てデータ
移行）。だから `migrate` だけではカラムが増えず、新しいエンティティが期待するカラムが
無くて全ページ 500 になる（4.2 → 4.3 なら `dtb_base_info.ga_id`）。逆に `schema:update`
だけではマスタデータが入らない。両方要る。

> 本体の migration は個々に存在チェックが入っているので、再実行しても二重適用にならない。

**`schema:update` は「エンティティ定義に無い列」を削除する。** `--complete` の有無は
関係ない（`--complete` 無しで削除を免れるのはテーブルだけで、既存テーブルに追加された
列は消える）。プラグインが `EntityExtension` で足した列（例: `dtb_customer.sort_no`）は、
その時点でプラグインが有効かつメタデータに載っていないと削除対象になる。

そのため `bin/upgrade.sh` は次の順で守っている。

1. `eccube:generate:proxies` — `eccube_app` を作り直すと `app/proxy/entity` が消えるので、
   有効なプラグインのエンティティ拡張をメタデータへ載せ直す
2. 差分 SQL に列・テーブルの削除が混じっていないか検査し、あれば**中止する**
   （`DROP INDEX` / `DROP FOREIGN KEY` / `DROP PRIMARY KEY` は索引の貼り直しなので除外）

意図的に削除を適用したいときだけ `UPGRADE_ALLOW_DROP=1 bin/upgrade.sh <version>`。

注意点:

- migration は前進のみ。**ダウングレードはできない。** 切り戻しは `.env` を戻して
  `bin/upgrade.sh <旧バージョン>` を実行し、必要なら `bin/restore.sh` で DB を書き戻す。
- マイナー/メジャーをまたぐ場合、既存プラグインが新バージョン非対応だと起動後にエラーに
  なりうる。事前に対応状況を確認すること。
- 完了後は管理画面・フロント・受注データを目視で確認すること。

複数バージョンを並行運用したい場合は、別ディレクトリに clone するか `.env` の
`COMPOSE_PROJECT_NAME` を分ける。

---

[← README へ戻る](../README.md)
