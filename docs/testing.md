# ユニットテスト

**`bin/test.sh` から実行する。** 素の phpunit だと prod カーネルが起動して全部落ちる。


自分のコードのテストは **`app/Customize/Tests/`** に置く（`Customize\` 名前空間で
autoload されるので、対象クラスをそのまま `use` できる。本体は汚さない）。

> ルート直下の `tests/` にしない理由: autoload には `composer.json` の追記が要るが、
> それはイメージにベイクされるため **バージョン切替（再ビルド）のたびに消える**。
> `Customize\` は本体 composer.json がどのバージョンでも保証するので、
> `app/Customize/Tests/` なら設定ゼロで切替後も壊れない。

```bash
bin/test.sh                       # 全テスト（app/Customize/Tests/）
bin/test.sh --filter testAddition # 絞り込み
bin/test.sh --testdox             # 読みやすい出力
bin/test.sh app/Plugin/Foo/Tests  # パス指定で任意のテストも実行できる
```

- 設定（プロジェクトルート）の testsuite は `app/Customize/Tests` に限定して
  いるが、**パスを引数で渡せばプラグインのテストもこの設定で走る**。
- EC-CUBE 本体のフルスイート（重い・DB 必須）は image の `phpunit.xml.dist` に残してある。
  必要なときだけ `docker compose exec ec-cube runuser -u www-data -- vendor/bin/phpunit -c phpunit.xml.dist`。

## 設定ファイルはバージョン別に 2 本

EC-CUBE のバージョンで PHPUnit の系列が変わり、設定の書式が相互に非互換になる。

| EC-CUBE | PHPUnit | DAMA | 設定ファイル | DAMA の登録 | カバレッジ対象 |
| --- | --- | --- | --- | --- | --- |
| 4.2 / 4.3 | 9.6 | 6.x | `phpunit.xml` | `<listeners><listener>` | `<coverage>` |
| 4.4〜 | 11 | 8.x | `phpunit.11.xml` | `<extensions><bootstrap>` | `<source>` |

**どちらを使うかは `bin/test.sh` が自動で選ぶ。** `.env` の `ECCUBE_VERSION` ではなく
コンテナの `vendor/bin/phpunit` の実バージョンを見るので、再ビルドや依存解決の結果が
ズレていても正しい方が選ばれる。バージョンを切り替えたあと、テスト側で何かする必要は無い。

書式が合わない設定を渡しても **PHPUnit は警告を出して読み飛ばすだけで止まらない**。
その結果 DAMA のロールバックが黙って無効化され、テストが本番と同じ DB に書き込み続ける
（実際に商品が 12,000 件残ってフロントが落ちた）。静かに壊れるのが最悪なので、
`bin/test.sh` は実行の前後で次を検査し、引っかかったら **テストが緑でも終了コード 1** を返す。

1. コンテナの PHPUnit のメジャーバージョンを取得し、対応する設定ファイルを選ぶ
2. ホストとコンテナで設定ファイルのバイト数が一致するか（bind mount の取り違え検出）
3. コンテナ側の設定を DOM で読み、DAMA の登録方法がそのバージョンと噛み合っているか
4. 実行ログに `The configuration file did not pass validation!` が出ていないか

## コンパイル済みコンテナが古いと、足したクラスが見えない

テストは `APP_DEBUG=0` で走る。`bin/console cache:clear` が作り直すのはデバッグ版
（`Eccube_KernelTestDebugContainer`）で、テストが使うのは別のファイル
（`Eccube_KernelTestContainer`）。**debug=false のコンパイル済みコンテナはファイルの
更新を一切見ない**ため、クラスを足しても登録されないまま残る。

症状は「サービスがコンテナに無い」形で出る。フォームの型なら次のようになる。

```
Too few arguments to function ...::__construct(), 0 passed in FormRegistry.php
```

Symfony が DI を通さず `new` している合図で、原因はコードではなくキャッシュ。
`cache:clear` を何度打っても直らない。

`bin/test.sh` が `app/Plugin` と `app/Customize` の php / yaml / xml をコンパイル済み
コンテナの更新時刻と比べ、新しいものがあれば `var/cache/test` を消してから実行する
（`Tests/` 配下はコンテナに入らないので数えない）。手で直すなら次のとおり。

```bash
docker compose exec ec-cube rm -rf var/cache/test
```

設定を編集するときは **両方のファイルを同じ内容に保つこと**（片方だけ直すと、
バージョンを切り替えた瞬間に差分が出る）。

## DB を使う統合テストを書くとき

`Eccube\Tests\EccubeTestCase` などを継承する統合テスト（`WebTestCase` 系を含む）は、
既定の設定でそのまま走る。

- **`APP_ENV=test` はコンテナのプロセス環境として渡す必要がある**（`bin/test.sh` が
  やっている）。コンテナは既定で `APP_ENV=prod` を持っており、Symfony の
  `KernelTestCase` は `$_ENV`/`$_SERVER` の `APP_ENV` を先に見るため、`phpunit.xml` の
  `<server>` 指定だけでは prod カーネルが起動し、
  `framework.test config is not set to true` で全部落ちる。
- **DAMA\DoctrineTestBundle をテスト設定に入れてある**。各テストが
  トランザクションで包まれてロールバックされるので、DB にデータが残らない。これが
  無いと実行のたびにレコードが積み上がり、件数を前提にしたテストが後から壊れる
  （実際に会員グループが数千件溜まって既存テストが落ちた）。バンドル自体は本体が
  test 環境向けに登録済み（`app/config/eccube/bundles.php`）。
- **メールはテスト環境だけ同期送信に戻してある**（`app/config/eccube/packages/test/messenger.yaml`）。
  本番の非同期送信設定が test にも効くと、`assertEmailCount()` を使うテストが
  「0 sent」で落ちる。詳細は「メール送信の非同期化」節。
- テスト用 DB は分けておらず、開発用の DB をそのまま使う。上のロールバックがあるので
  データは汚れないが、**本番の DB では絶対に実行しないこと**。
- **管理画面の Web テストだけは Member が残る。** `AbstractAdminWebTestCase` は
  メソッドごとに Member を作るが、Web テストは購入フローなどが明示的に commit するため
  ロールバックされない。`Generator::createMember()` は
  `do { $loginId = $faker->word; } while (既存)` で未使用の login_id を探すので、
  **残った Member が faker の単語の総数（ja_JP で 182 語）に達すると永久に抜けられない**。
  エラーもタイムアウトも出ず、PHP が CPU を回し続けるだけなので原因を追いにくい。
  `bin/test.sh` は実行前に件数を数え、単語が尽きそうなら `login_id` を
  `leaked-<id>` へ退避して空ける（行は消さないので `creator_id` などの参照は壊れない）。
  退避が失敗するときは `bin/reset.sh` で DB を初期化する。

> `phpunit.xml` / `phpunit.11.xml` は単一ファイルとして bind-mount している。ホスト側で
> 編集すると inode が変わってコンテナ側が古い内容を見続けるので、
> `docker compose up -d --force-recreate ec-cube` でマウントを張り直す
> （`bin/test.sh` がバイト数の食い違いで検出して止める）。

---

[← README へ戻る](../README.md)
