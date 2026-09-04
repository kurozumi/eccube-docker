# 導入手順

配布されたイメージを引いて店を立ち上げ、以後の更新を受け取れる状態にするまで。

**本体を改造しないなら、手元でビルドする必要はない。**

配布する側の話（タグの設計、リリースの打ち方）は [配布と更新](distribute.md)。

## 必要環境

- Docker Engine / Docker Compose v2.24 以上（`compose.prod.yaml` で `!override` を使用）
- amd64 / arm64 どちらも可

---

## そのまえに: 何を選ぶか

最初に決めるのはこれだけで、あとの手順は共通。

| | 配布イメージを引く（推奨） | 手元でビルドする |
|---|---|---|
| 誰が | 使うだけの人 | 本体を改造する人 |
| `.env` | `ECCUBE_IMAGE` を書く | `ECCUBE_IMAGE` を**書かない** |
| 起動 | 数十秒 | 数分（composer の依存解決を含む） |
| 中身 | 全員が同じもの | 取得したタイミングで変わりうる |

```bash
# 引いて使う場合の .env
ECCUBE_IMAGE=ghcr.io/kurozumi/eccube-docker/ec-cube:4.3-v1.0.0
```

判定はスクリプト側（`bin/lib/image.sh`）が行うので、`bin/init.sh` /
`bin/upgrade.sh` / `bin/switch-version.sh` / `bin/publish.sh` の打ち方は
どちらでも変わらない。

---

## 1. 自分のリポジトリを作る

**`git clone` しない。** clone すると origin が配布元のままで、あなたのコードを
あなたの GitHub で管理できない。**リリースの中身だけを取り出して、自分のリポジトリ
として始める。**

```bash
# 1) リリースを取得する（git 履歴は付いてこない）
curl -fsSL https://github.com/kurozumi/eccube-docker/archive/refs/tags/v1.0.0.tar.gz | tar -xz
mv eccube-docker-1.0.0 myshop && cd myshop

# 2) 自分のリポジトリとして初期化する
git init -b main
git add -A
git commit -m "eccube-docker v1.0.0 から開始"

# 3) 自分の GitHub へ。**非公開で作る**（店のコードと設定が入るため）
gh repo create myshop --private --source=. --push
```

`app/`（Customize / template / DoctrineMigrations / Plugin）と
`html/user_data`（独自 CSS/JS）は**あなたの成果物**なので、ここで Git 管理する。
EC-CUBE 本体はイメージの中にあり、このリポジトリには 1 ファイルも入らない。

### なぜ clone / fork / テンプレートではないのか

| 方法 | 問題 |
|---|---|
| `git clone` | origin が配布元のまま。あなたの履歴に配布元の履歴が丸ごと混ざる |
| fork | **公開リポジトリの fork は非公開にできない。** 店のコードを置く場所として使えない |
| テンプレート | **リリースではなく `main` の先頭が複製される。** `main` が最後のタグより進んでいると、`VERSION` は `v1.0.0` なのに中身が違う状態になり、`bin/self-update.sh` がその差分を「あなたの変更」と判定して止まる |

`bin/self-update.sh` は **git を使わない**（Releases の tarball を取ってきて突き合わせる）。
配布元とは git 上の関係を持たなくてよいので、tarball から始めるのが一番素直になる。
`ECCUBE_DOCKER_REPO` を origin から推測しないのも同じ理由で、**あなたの origin は
あなたのリポジトリであって、配布元ではない**。

### 決めておくこと

- **`.env` はリポジトリに入らない**（`.gitignore` 済み）。シークレットの控えは
  パスワードマネージャなど別の場所に置く。**`.env` を失うと DB のパスワードが分からなくなる。**
- **`app/Plugin/*` も既定では追跡しない。** 買ったプラグインはそれぞれの提供元が持つもの
  だという前提。自分で開発するプラグインは、別リポジトリにして `bin/plugin.sh add` で
  入れるか、`.gitignore` の該当行を外して一緒に管理する。**どちらでもよいが、最初に
  決めておくこと。**
- **配布元が非公開なら**、`gh auth token` などで取った値を `GITHUB_TOKEN` に入れておく
  （取得も `bin/self-update.sh` も、あれば使う）。

## 2. 設定を作る

```bash
cp .env.example .env
```

引いて使うなら `ECCUBE_IMAGE` を書く。`ECCUBE_AUTH_MAGIC` と DB のパスワードは
次の手順で自動生成されるので触らなくてよい。

**タグは必ず系列（`4.3` など）で始まるものを選ぶ。**

| タグ | 意味 |
|---|---|
| `4.3-v1.0.0` | 系列 4.3 ／ 環境 v1.0.0。**これを使う**。中身が動かない |
| `4.3` | 系列 4.3 の最新リリース。pull し直すたび中身が変わってよいなら |
| `4.3-<sha>` | 特定ビルド。ロールバック用 |

**`latest` は用意していない。** 4.2 / 4.3 / 4.4 が並行して現役なので、単一の「最新」を
置くと、利用者は自分がどの系列を引くのか指定できないまま、**マイナーをまたぐ更新を
引き当てる**ことになる。マイナーはプラグイン全数の移植を伴う（[バージョンアップ](upgrade.md)）。

## 3. 立ち上げる

```bash
bin/init.sh
```

`ECCUBE_IMAGE` があれば pull、なければビルドする。シークレットの生成、DB の作成、
初期データの投入まで通しで行う。

```bash
docker compose logs -f ec-cube   # 落ち着けば完了
```

## 4. 画面を見る

| 用途 | URL |
|---|---|
| フロント | http://localhost:8080/ |
| 管理画面 | http://localhost:8080/admin/ |
| メール確認（開発） | http://localhost:8025/ |
| DB 管理（開発） | http://localhost:8081/ |

既定は本番モード（`.env` の `APP_ENV=prod`）。デバッグするときだけ `APP_ENV=dev` /
`APP_DEBUG=1` にして起動し直す。

## 5. プラグインを入れる

```bash
bin/plugin.sh add git@github.com:you/MyPlugin.git   # clone→install→enable
bin/plugin.sh list                                  # 導入状況
```

**管理画面（オーナーズストア → プラグイン一覧）から有効化・無効化したら、その直後に
`bin/plugin.sh reload` を実行する。** 本体はキャッシュを組み立て直さないため、
古いエンティティクラスを掴んだままメタデータが作られることがある。

    Unrecognized field: Plugin\CustomerGroup44\Entity\Group::$optionCompanyEntry

**落ちるのは有効化した画面ではなくフロントの別ページ**なので、原因にたどり着きにくい。

**素の `bin/console eccube:plugin:enable` は直接叩かない。** 前後に必要なキャッシュ操作が
あり、怠るとコマンドが異常終了するか、トレイトで足した getter が**例外も出さずに
空のコレクション**を返す（詳細は [カスタマイズ](customize.md)）。

## 6. 公開する（本番のみ）

```bash
bin/publish.sh
```

公開方式は `.env` の `COMPOSE_PROFILES` で選ぶ（`tunnel` / `caddy` / 空）。
詳細は [本番デプロイ](deploy.md)。

シークレットが既定値のままだと止まる。これは意図した動作で、
`FORCE_PUBLISH=1` で越えられるが、越える前に `.env` を直すこと。

---

## 運用: 「更新」は二つある

**混ぜると事故る。順番は 環境 → 本体。** 逆にすると、新しい本体を古いスクリプトで
扱うことになる（本体の作法が変わったとき、その差分を知らないスクリプトが動く）。

| | 環境の更新 | EC-CUBE 本体の更新 |
|---|---|---|
| 何が変わる | `bin/` `docker/` `compose*.yaml` `docs/` | イメージに焼かれた本体・vendor・PHP 拡張 |
| コマンド | `bin/self-update.sh` | `bin/upgrade.sh <制約>` |
| データ | 触らない | DB と画像は残す（migration は前進する） |

```bash
bin/self-update.sh --check   # 何が変わるか見るだけ
bin/self-update.sh           # 環境を更新

bin/upgrade.sh ~4.3.2        # 本体を更新
bin/upgrade.sh ~4.3.2 --prod # 本番はこちら
```

`bin/self-update.sh` は **`.env` / `app/` / `html/user_data` / `frontend/` に触らない。**
あなたが手を入れた環境ファイルが更新でも変わる場合は、上書きせずに止まる。
`.env.example` にキーが増えていたら一覧で出す（**未設定でも compose の既定値で起動して
しまい、エラーにはならない**ため）。詳細は [配布と更新](distribute.md)。

**本番で `bin/upgrade.sh` を打つときは `--prod` を落とさない。** 落とすと
`compose.override.yaml`（開発用のポートと bind mount）が効いた状態で公開される。
**画面は出るので気づきにくい。**

### 更新のあと

```bash
docker compose up -d --force-recreate
```

単一ファイルの bind mount（`phpunit.xml` など）はホスト側で書き換えても inode が変わって
コンテナ側へ反映されないことがあり、中途半端な内容を掴んだまま起動する。

### 更新を自分のリポジトリに残す

`bin/self-update.sh` は作業ツリーのファイルを書き換えるだけで、**コミットはしない。**
何が変わったのかを見てから、あなたのコミットとして残す。

```bash
git diff --stat        # 何が変わったか
bin/test.sh            # 動くか
git add -A
git commit -m "環境を v1.1.0 へ更新"
git push
```

こうしておくと、**次の更新で「あなたが変更したファイル」を正しく判定できる**
（判定は配布元のリリースとの突き合わせなので、コミットの有無そのものには依存しないが、
更新が壊れたときに `git revert` で戻せるのはコミットしてある場合だけ）。

---

## 詰まったとき

この環境の不調は、ほとんどがキャッシュかプラグインの状態。

| 症状 | まず打つもの |
|---|---|
| システムエラーが出る | `bin/plugin.sh doctor` — 残骸の掃除・無効プラグインの検出・キャッシュの組み立て直し・疎通確認まで行う |
| 直したのに反映されない | `bin/plugin.sh reload` — 本番モードでは OPcache と Redis 上のメタデータが残り、**足したサービスやタグだけが例外も 500 も出さずに効かない** |
| フロントだけ 503（メンテナンス中） | `bin/plugin.sh doctor` — 中断した操作で `.maintenance` が残っている。**管理画面は素通りできるので気づきにくい** |
| コンテナに繋がらない | `bin/console.sh` などが、どのスタックで動いているかを名前ごと出す。`.env` に `COMPOSE_PROJECT_NAME` を書いて固定する |
| テストが動かない | `bin/test.sh` を使う。素の `vendor/bin/phpunit` はコンテナの `APP_ENV=prod` が勝って prod カーネルで起動し、`WebTestCase` 系が全部落ちる |

**`bin/reset.sh` と `bin/switch-version.sh` は DB・画像・セッションを消す。**
その場では戻せない。上げたいだけなら `bin/upgrade.sh`。
詳細は [データを失わないために](data-safety.md)。

---

## いまの制約

- **リリースタグ（`v1.0.0`）はまだ打たれていない。** 配布イメージと
  `bin/self-update.sh` は最初のリリース以降に有効になる。それまでは手元で
  ビルドする経路を使うこと。
- **EC-CUBE 4.4 は Packagist にリリースが無い。** 上流の `4.4` ブランチ
  （`4.4.x-dev`）から焼いているので、**同じタグでも焼き直すたびに中身が変わる。**
  本番で 4.4 を使うなら `4.4-<sha>` で固定すること。

---

[← README へ戻る](../README.md)
