# 配布と更新

この環境を人に渡し、こちらが直したら向こうも新しくできるようにするための話。

**「更新」は 2 つある。混ぜると事故る。**

| 何を | 中身 | コマンド |
|---|---|---|
| 環境 | `bin/` `docker/` `docs/` `compose*.yaml` `.env.example` `app/config/eccube/{packages,optional}` | `bin/self-update.sh` |
| EC-CUBE 本体 | イメージに焼かれた本体・vendor・PHP 拡張 | `bin/upgrade.sh <制約>` |

順番は **self-update → upgrade**。逆にすると、新しい本体を古いスクリプトで扱うことに
なる（本体の作法が変わったとき、その差分を知らないスクリプトが動く）。

---

## 利用者側: 使うだけの人

**入手は `git clone` ではない。** リリースの tarball から始めて、自分のリポジトリとして
初期化する（clone だと origin が配布元のままで、利用者は自分のコードを自分の GitHub で
管理できない）。手順は [導入手順](install.md) を見ること。

`bin/self-update.sh` が **git を一切使わない**（Releases の tarball を取ってきて
突き合わせる）のはこのため。利用者のリポジトリは配布元と git 上の関係を持たなくてよい。

本体を改造しないなら、**手元で build する必要はない。** `.env` に配布イメージを書く。

```bash
# .env
ECCUBE_IMAGE=ghcr.io/kurozumi/eccube-docker/ec-cube:4.3-v1.0.0
```

これだけで `bin/init.sh` は build せずに pull する。初回の起動が数分から数十秒になる。

### タグの選び方

| タグ | 意味 | 用途 |
|---|---|---|
| `4.3` | 最新リリースの Dockerfile を**毎週焼き直したもの** | **本番。** PHP / Debian のパッチが最長 1 週間で入る |
| `4.3-php8.3` | 同上、PHP を選ぶ | 4.2: 8.1/8.2、4.3: 8.1/8.2/8.3、4.4: 8.2〜8.5 |
| `4.3-20260907` | その週の焼き直しを日付で固定 | 検証環境、複数ホストで同一を保証 |
| `4.3-v1.0.0` | リリース時点で固定 | 再現用。パッチは入らない |
| `4.3-<sha>` | 特定ビルド | ロールバック |

**`latest` は無い。** EC-CUBE は 4.2 / 4.3 / 4.4 が並行して現役なので、単一の「最新」を
置くと、利用者は自分がどの系列を引くのか指定できないまま、**マイナーをまたぐ更新を
引き当てる**ことになる。マイナーはプラグイン全数の移植を伴う（`docs/upgrade.md`）。

### 4.4 は動く的

**EC-CUBE 4.4 は Packagist にリリースが 1 つも無く、上流にあるのは `4.4` ブランチだけ。**
そのため制約は `4.4.x-dev` を使う（`~4.4.0` も `dev-4.4` も解決できない）。

つまり **4.4 のイメージは「焼いた時点のブランチの写し」で、再現しない。** 同じ
`4.4-v1.0.0` を焼き直しても中身は変わる。本番で 4.4 を使うなら `4.4-<sha>` で固定すること。
4.4 が正式に出たら、CI の matrix を `~4.4.0` へ変える。

### 環境を更新する

```bash
bin/self-update.sh --check   # 何が変わるか見るだけ
bin/self-update.sh           # 更新する
```

やること・やらないこと:

- **`.env` は絶対に書き換えない。** あなたの設定なので。ただし `.env.example` に
  キーが増えていたら一覧で出す。**未設定でも compose の既定値で起動してしまい、
  エラーにはならない**ので、ここは自分で見る必要がある。
- `app/` `html/user_data` `frontend/` `var/` `backups/` にも触らない。
- 環境ファイルのうち、**配布元が変えたファイルだけ**を差し替える。`bin/` に自分で
  置いたスクリプトは残る。
- あなたが環境ファイルに手を入れていて、**そこが更新でも変わる**なら、上書きせずに
  止まる。承知のうえなら `--force`。

判定は「いま入っている版のリリース」と突き合わせて行う（手元に控えを持たない）。
その版が配布元から取れないと判定できないので、そのときは黙って進まず止まる。

更新後は設定ファイルの inode が変わっているので、コンテナを作り直すこと:

```bash
docker compose up -d --force-recreate
```

### 配布元を変える

fork して自分たちで配る場合は `.env` に書く。

```bash
ECCUBE_DOCKER_REPO=your-org/your-fork
```

**origin からは推測しない。** 店が自分のリポジトリで管理しているとき、origin は
配布元ではない。推測すると、リリースを持たない自分の repo を見に行って
「更新なし」と言い続けることになる。

---

## 配布側: リリースする

### 1. バージョンを上げる

`VERSION` に環境のバージョンを書く（`1.1.0` のように `v` は付けない）。
利用者の `bin/self-update.sh` はここを見て「いま何が入っているか」を判断する。

### 2. タグを打つ

```bash
git tag v1.1.0 && git push origin v1.1.0
```

`.github/workflows/build-image.yml` が動き、**対応する全系列**のイメージを焼いて
GHCR へ push する。

**初回は、GHCR のパッケージが匿名で pull できるか確かめる。**

```bash
curl -s "https://ghcr.io/token?scope=repository:<owner>/<repo>/ec-cube:pull" | jq -r .token \
  | xargs -I{} curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer {}' \
    https://ghcr.io/v2/<owner>/<repo>/ec-cube/tags/list      # 200 なら公開
```

Actions の `GITHUB_TOKEN` で公開リポジトリから push したパッケージは、**リポジトリの
公開範囲を引き継いで public になる**（v1.0.0 で実際にそうなった。パッケージを消して
作り直しても同じ）。手元から `docker push` した場合や、リポジトリが非公開の場合は
非公開で作られるので、そのときは画面で切り替える:

```
Packages → ec-cube → Package settings → Danger Zone → Change visibility → Public
```

非公開のままだと利用者の pull は**「認証しろ」の形で失敗する**ので、原因にたどり着きにくい。系列ごとに PHP と phpredis が違う（phpredis は EC-CUBE 側の
Symfony Cache と両立しないバージョンがあり、間違えると起動時に落ちる）。対応表は
2 か所にあり、**必ず揃えること**:

- `bin/lib/image.sh` の `image_php_for_series` / `image_phpredis_for_series`
- `.github/workflows/build-image.yml` の `setup` ジョブ

### 3. リリースノートに書くこと

- **対応する `ECCUBE_VERSION`**（どの系列のイメージを焼いたか）
- `.env.example` に増えたキーと、既定値のままだと何が起きるか
- 破壊的変更（利用者が手を入れている可能性が高いファイルを変えたなら、その旨）

利用者は `bin/self-update.sh` の最後に出るリンクからここへ来る。

### 紹介ページ

`site/index.html` を GitHub Pages に配る（`.github/workflows/pages.yml`）。**Release を出したときに
自動で更新される**（手動実行も可）。ページ内の `__TAG__` / `__VER__` は配る直前に最新 Release の
番号で置き換わるので、版を書き換えて回る必要は無い。`site/` は配布物から外してある。

### リリースの添付と、self-update の検証

release を publish すると `release-assets.yml` が **`eccube-docker-<ver>.tar.gz`**（`git archive`。
`.gitattributes` の `export-ignore` を尊重）、**`SHA256SUMS`**、**署名（attestation）** を付ける。
`bin/self-update.sh` はこれを取り、

1. `SHA256SUMS` と突き合わせる（合わなければ展開しない）
2. `gh` があってログイン済みなら `gh attestation verify`（「このリポジトリのワークフローが
   このコミットから作った」の署名。合わなければ展開しない）

を通してから展開する。入れるのは `docker-entrypoint.sh` や `deploy.sh` のようにホストで root
相当の権限で動くものなので、受け手が真正性を確かめられるようにしてある。添付の無いリリース
（v1.0.2 以前、publish 直後の数十秒）は GitHub 自動生成の tar.gz に落ち、**「検証なし」と出す**。
古いリリースに後から付けるには `release-assets.yml` を `workflow_dispatch` で tag 指定。

手で確かめるなら:

```bash
gh release download v1.0.3 -p 'eccube-docker-*.tar.gz' -p SHA256SUMS
sha256sum -c SHA256SUMS                                   # macOS: shasum -a 256 -c
gh attestation verify eccube-docker-1.0.3.tar.gz --repo kurozumi/eccube-docker
```

### 試し焼き

`workflow_dispatch` で系列を指定して実行する。**追跡タグ（`4.3` など）は動かず**、
`4.3-<sha>` だけができる。試し焼きが利用者に配られないようにするため。

### いつ回るか

| きっかけ | 動き |
|---|---|
| タグ push（`v*`） | 全系列 × PHP を焼いて GHCR へ push（＝リリース）。`-vX.Y.Z` と追跡タグが動く。**`docker/php/**` とこのワークフローが前のタグから変わっていなければ焼かず**、追跡タグ（直近の焼き直し）に `-vX.Y.Z` の名前を足すだけ（文書や bin/ だけのリリースで 9 通りを回さない） |
| **毎週月曜 03:00 JST** | **最新リリースのタグ**の Dockerfile を、キャッシュ無し・土台を引き直して焼く。追跡タグ（`4.3` / `4.3-php8.3`）と日付タグ（`4.3-20260907`）が動く。`-vX.Y.Z` は動かない |
| PR を**開いた**とき | `docker/php/**` かこのワークフローを触っていれば build だけ（push しない） |
| 手動実行 | 指定系列を焼いて `<系列>-<sha>` だけ push。`refresh` を付けると毎週と同じ扱い（**PHP に重大な脆弱性が出た日はこれで当日焼く**） |

### 毎週の焼き直しが何のためか

PHP の月例パッチ（第 2 木曜前後）と Debian のパッチを配るため。土台は `php:8.3-fpm-bookworm` の
ような浮動タグなので、**焼き直すだけで新しい PHP と OS パッケージが入る**。ただし GHA の
キャッシュが apt の layer に当たると入らないので、焼き直しではキャッシュを使わない
（1 回 3〜4 分 × 9 = 月に 2 時間強。公開リポジトリなので無料）。

利用者側は `ECCUBE_IMAGE` を追跡タグ（`4.3`）にしておけば、`bin/deploy.sh` が
「動いているイメージと違う」と見て引き直す。**PHP のパッチに `upgrade.sh` は要らない**
（PHP は本体コードのボリュームの外にある）。

ブランチへの push では回らない。`main` で回すと利用者が引くものが予告なく変わり、
保守ブランチで回すと直接 push のたびに走る。

**`pull_request` の `types` を省かないこと。** 省くと既定に `synchronize` が入り、
**PR ブランチへ push するたびに matrix 全ジョブが回る**（4.4 の実ビルドは 1 回 3 分半）。
`push:` を消しただけでは止まらない。

その代わり **PR を開いたあとに Dockerfile を直しても CI は回らない。** チェックの結果は
最新コミットのものとは限らないので、確かめ直すときは手動実行を使う。

---

### 焼き直しで変わるもの・変わらないもの

追跡タグを引き直して `up -d` しても、**EC-CUBE 本体のコードと vendor は変わらない。**
`/var/www/html` は `eccube_app` ボリュームが覆っていて、イメージ側の本体はその下に隠れる
（`bin/upgrade.sh` の頭のコメント参照）。変わるのはボリュームの外にあるもの:

| 変わる（イメージ側） | 変わらない（ボリューム側） |
|---|---|
| PHP 本体と拡張、php-fpm | EC-CUBE 本体（`src/` `app/` `vendor/`） |
| Debian のパッケージ | DB のスキーマ（migration は走らない） |
| entrypoint、php.ini | `.env`（コンテナ内） |

だから `bin/deploy.sh` が毎日イメージを引き直しても、**本体のバージョンは上がらない**。
本体を上げるのは `bin/upgrade.sh` だけで、そちらは退避 → 新しい本体でプラグインが読めるかを
稼働中に触る前に確認 → メンテナンス表示 → migration、と検証を挟む。「追跡タグは検証なしで
本体のパッチを本番に流す」は当たらない（#113）。同じものを何度も立てたいときの再現性は
日付タグ（`4.3-20260907`）で。

## 本体を改造する人

`ECCUBE_IMAGE` を設定しなければ、これまでどおり手元で build する
（`bin/init.sh` / `bin/upgrade.sh` / `bin/switch-version.sh` / `bin/publish.sh` が
自動で判断する）。

**起動系のスクリプトに `up -d --build` を直接書かないこと。** 配布イメージを
使っている利用者の環境でそれを打つと、pull したイメージをローカル build で
上書きしてしまう。判定は `bin/lib/image.sh` の `image_provision` に寄せてある。

## 配布イメージのときの落とし穴

**`.env` の `ECCUBE_VERSION` は build にしか使われない。** 実際に動くのは
イメージのタグに焼かれたバージョンなので、両者は簡単にずれる。

- `bin/upgrade.sh` は pull したイメージに**実際に焼かれているバージョンを表示して
  確認を求める**。`~4.3.2` と指定しても、タグが 4.3 系の古いビルドを指していれば
  4.3.0 が来る。
- 系列をまたぐとき（4.3 → 4.4）、`bin/upgrade.sh` と `bin/switch-version.sh` は
  `ECCUBE_IMAGE` のタグの**系列部分だけ**を書き換える。`4.3-v1.0.0` → `4.4-v1.0.0`。
  系列で始まらないタグ（`latest` など）は何を指すか分からないので書き換えず、
  警告して素通りする。
