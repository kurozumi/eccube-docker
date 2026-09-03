# IDE の設定

PhpStorm でコード補完を効かせる。**本体と vendor はボリュームの中だけにあり、ホストには1ファイルも無い。**


本体は名前付きボリューム `eccube_app` に展開され、bind-mount しているのは `app/` と
`html/user_data` だけ。つまり **ホストには `vendor` も `src/Eccube` も 1 ファイルも無い**。
IDE から見れば `Eccube\Entity\Order` も Symfony も Doctrine も未定義のクラスで、補完も
定義ジャンプも効かない。

**リモートインタプリタ（Docker Compose）を設定しても直らない。** あれが読むのは PHP 本体の
バージョンと拡張だけで、composer の依存は解決しない。ホストに実体を置くしかない。

```bash
bin/ide-sync.sh            # 本体（src/Eccube）と vendor を .ide/ へ写す
bin/ide-sync.sh --proxy    # app/proxy/entity も（エンティティ拡張を書くとき）
bin/ide-sync.sh --clean    # .ide/ を消す
```

そのあと PhpStorm で（初回だけ）:

  Settings → Languages & Frameworks → **PHP** → **Include Path** タブ → `+` で
  `.ide/vendor` と `.ide/src` を追加

- **ソースルート（`.iml` の `sourceFolder`）には足さないこと。** Include Path なら
  解決だけに使われ、Find in Files や Refactor の対象からは外れる。ソースルートにすると
  「自分のコード」の検索結果が vendor 200MB に埋もれる。
- `.ide/` は `.gitignore` 済み。イメージの複製なので消しても作り直せる。**編集しても
  コンテナには反映されない**（実行されるのはボリューム側）。
- `--proxy` で出る `app/proxy/entity` は、EntityExtension トレイトを適用し直した
  エンティティの生成物。プラグインが足したプロパティや getter はここにしか無い。ただし
  `src/Eccube/Entity` と FQCN が衝突する（同じクラスが 2 か所で定義されて見える）ので、
  エンティティ拡張を書いている間だけ入れるのが実際的。
- **バージョンを切り替えたら写しは古い。** `bin/switch-version.sh` / `bin/upgrade.sh`、
  あるいはイメージを再ビルドしたら実行し直す。`.ide/.synced` に写した時点のバージョンと
  日時が入っている。

---

[← README へ戻る](../README.md)
