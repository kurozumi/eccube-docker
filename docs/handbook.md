# はじめての人のための手引き

理由は書きません。「なぜ」が知りたくなったら、各所のリンク先を読んでください。
ここは**手を動かすためだけ**の文書です。

Claude Code などの AI に運用を手伝わせるなら、このディレクトリの `AGENTS.md` がその AI 向けの
指示書です（やること・やってはいけないことが書いてある）。「AGENTS.md を読んで、初回の
セットアップをして」で始められます。

---

## 先に 1 つだけ

Mac ならターミナル、Windows なら **WSL2（Ubuntu）** を入れて、その中で進めます
（このリポジトリの `bin/` は bash のスクリプトで、PowerShell では動きません）。
Docker Desktop は WSL2 の中からも使えます。

## 登場するものは 5 つ

```
 あなたのパソコン ──(git push)──▶ あなたのリポジトリ ──(git pull)──▶ サーバー ──▶ お客さんのブラウザ
   直す・試す                     控え（非公開）              動かす           見る
        ▲
        │ (self-update)  この仕組みの新しい版を取り込む
 配布元（eccube-docker）
```

- **あなたのパソコン** … ここで直して、ここで試す
- **あなたのリポジトリ** … 直したものの控え。あなた専用の GitHub リポジトリ（**非公開**）。作り方は次の節
- **サーバー** … お店が動いている場所。**ここでは直さない。** あなたのリポジトリから持ってくるだけ
- **お客さんのブラウザ** … 見るだけ
- **配布元** … この仕組み（`eccube-docker`）の置き場。サーバーとは直接つながらない

「直す場所」と「動かす場所」を分けるのが、この仕組みの全部です。

---

## 「上げる」相手は 3 つある

| 名前 | 何か | 番号の形 |
|---|---|---|
| **EC-CUBE** | お店のソフト（商品・カート・管理画面）。脆弱性の案内が来るのは、たいていここ | `4.3.2`（v が付かない） |
| **eccube-docker** | EC-CUBE を動かす台と道具（`bin/` のコマンドやサーバーの組み立て） | `v1.0.19`（v が付く） |
| **PHP** | EC-CUBE を動かす言語 | `8.3` |

何がしたいかで、やることが決まります。

```
お店をこれから作る ─────────────────▶ 最初に 1 回だけやること（下）
EC-CUBE の案内が来た／新しい版が出た ──▶ 環境を新しくしてから、bin/upgrade.sh（バージョンアップ）
eccube-docker の新しい版が出た ────────▶ bin/self-update.sh（この仕組みに更新があったとき）
PHP の脆弱性の案内が来た ──────────────▶ いつもの bin/deploy.sh だけ（翌朝の配布イメージに入っている）
                                          ※ .env に ECCUBE_IMAGE が無い（手元で build している）なら bin/deploy.sh --rebuild
自分で直したところを出したい ──────────▶ いつもの bin/deploy.sh（毎日やること）
```

図で見たいときは [紹介ページの「やりたいことから選ぶ」](https://kurozumi.github.io/eccube-docker/#howto)。

---

## 「あなたのリポジトリ」とは

この文書で **あなたのリポジトリ** と言ったら、**あなたのお店専用の、非公開の GitHub リポジトリ**
のことです。この仕組み（`eccube-docker`）そのものではありません。

**やってはいけない 2 つ:**

| やり方 | 何がまずいか |
|---|---|
| `eccube-docker` を **fork** する | 公開リポジトリの fork は**非公開にできない**。お店のコードが世界に見える |
| `eccube-docker` を **clone** してそのまま使う | 送り先（origin）が配布元のまま。**あなたのコードを保存する場所が無い** |

正しくは「配布元から**中身だけ**をもらって、**自分の**リポジトリとして始める」です。

## 最初に 1 回だけやること

### 1. あなたのパソコンで、あなたのリポジトリを作る

```bash
# 配布元の最新リリースの中身をもらう（git の履歴は付いてこない）
curl -fsSL https://github.com/kurozumi/eccube-docker/releases/latest/download/eccube-docker.tar.gz | tar -xz
mv eccube-docker-* myshop && cd myshop

# 自分のリポジトリとして始める
git init -b main
git add -A
git commit -m "eccube-docker から開始"

# GitHub に、非公開で置く（これが「あなたのリポジトリ」）
gh repo create myshop --private --source=. --push
```

この URL は**常に最新のリリース**を指します（版の番号を調べる必要はありません）。
何が入っているかは https://github.com/kurozumi/eccube-docker/releases で読めます。

このあと、あなたのパソコンでお店が動きます（終わると URL とログイン情報が表示されます）:

```bash
bin/init.sh --image=ghcr.io/kurozumi/eccube-docker/ec-cube:4.3-php8.3
```

`--image` は「配布イメージを引く」指定で、数十秒で終わります（付けないと手元でビルドするので
10 分以上かかる）。**PHP はタグの `php8.3` の部分で決まります。**

### 2. サーバーを整えて公開する（全部あなたのパソコンから打つ）

サーバー（VPS）を借りて SSH で入れるようにしたら、**サーバーには何も入れに行きません。**
手元から順番に打つだけです。

```bash
bin/bootstrap-server.sh user@サーバー /srv/myshop   # Docker を入れ、店のファイルを送り、.env を作る（1 分）
bin/setup.sh mail --remote=user@サーバー:/srv/myshop  # 送信メールを質問に答えて設定（先に 1 通試す）
bin/setup.sh tunnel --remote=user@サーバー:/srv/myshop # Cloudflare Tunnel のトークンを貼る（繋がるか試してから書く）
bin/publish.sh --remote=user@サーバー:/srv/myshop    # 公開する
bin/setup.sh backup --remote=user@サーバー:/srv/myshop # バックアップの送り先と毎日の自動実行
```

サーバーに git も GitHub の鍵も置きません。以後の反映も `bin/deploy.sh --remote=…` で
**手元から送ります**。

細かい判断（`.env` の中身、公開方式、プラグインの扱い）は [導入手順](install.md)。

---

## 毎日やること（3 つ）

### 1. あなたのパソコンで直す

| 直したいもの | 触る場所 |
|---|---|
| 見た目（CSS） | `frontend/scss/customize.scss` → `bin/assets.sh build` |
| 画面の部品（twig） | `app/template/original/` に**直すファイルだけ**置く |
| プラグインの画面・メール文面 | `bin/plugin.sh template add <Code> <ファイル>` で写してから直す。**管理画面からは直さない** |
| 動き（PHP） | `app/Customize/` |
| プラグイン | `bin/plugin.sh add <URL>` |

直したら、ブラウザで http://localhost:8080/ を開いて確かめます。
反映されないときは `bin/plugin.sh reload`。

### 2. 控えを送る

```bash
git add -A
git commit -m "何を直したか"
git push
```

### 3. サーバーに反映する

```bash
bin/deploy.sh --remote=shop:/srv/myshop     # あなたのパソコンから
```

または、サーバーに入って `bin/deploy.sh`。

これ 1 つで、**退避 → メンテナンス表示 → 取り込み → データベース更新 → キャッシュ →
確認 → メンテナンス解除** まで全部やります。数分かかります。**途中で止めないでください。**

本番には、**`main` の先頭と同じものしか送れません**。別のブランチにいる、コミットしていない
変更がある、push していない、のどれかだと止まります。出す前に「何が出るか」を見せて、
**プロジェクト名を打つ**まで何も変えません。見るだけなら `--check`。
複数人で運用する（エンジニアが直して担当者が出す）なら [誰が・何を・どうやって本番へ出すか](deploy.md#誰が何をどうやって本番へ出すか)。

終わったら、お店をブラウザで開いて目で確かめます。

---

## 管理画面で直したものは、サーバーにしか無い

CSS 管理・メール設定の本文・ページ管理・ブロック管理は、**サーバーのファイルに書きます。**
あなたのパソコンにも、あなたのリポジトリにも、自動では入りません。

サーバーの `bin/backup.sh`（と `bin/deploy.sh` の最初）には入るので、消えはしません。
ただし**リポジトリに残す**には、あなたのパソコンで取り込んで commit します。

```bash
bin/pull-admin-files.sh shop:/srv/myshop     # サーバーから取り込む
git add app/template html/user_data
git commit -m "管理画面で直した分を取り込む" && git push
```

`bin/deploy.sh` は、取り込まれていない管理画面の編集があると教えてくれます。

## この仕組み（eccube-docker）に更新があったとき

配布元が `bin/` や `docker/` を直すことがあります。**サーバーではやりません。**
あなたのパソコンで取り込んで、いつもの 3 手順で流します。

```bash
# あなたのパソコンで
bin/self-update.sh --check     # 新しい版があるか、何が変わるか（まだ何も書き換えない）
bin/self-update.sh             # 取り込む。あなたのコードと .env には触らない

# 動くか確かめて
bin/test.sh
# ブラウザで http://localhost:8080/ を開く

# いつもどおり
git add -A && git commit -m "eccube-docker を v1.1.0 へ" && git push
bin/deploy.sh --remote=shop:/srv/myshop
```

`self-update.sh` は「配布元が変えたファイル」だけを差し替えます。あなたが手を入れた
ファイルが更新でも変わる場合は、上書きせずに止まって知らせます。
`.env` に新しい項目が増えていたら一覧で出るので、必要なものを自分で足してください。

つまり流れはいつも同じです:

```
配布元 ──(self-update)──▶ あなたのパソコン ──(push)──▶ あなたのリポジトリ ──(deploy)──▶ サーバー
```

## ときどきやること

| いつ | 何を | どこで |
|---|---|---|
| 月に 1 回くらい | `bin/self-update.sh --check`（上の節） | あなたのパソコン |
| EC-CUBE の新しい版が出たとき | 先に「この仕組みに更新があったとき」を済ませ、あなたのパソコンで `bin/upgrade.sh ~4.3.0` を試し（表示される「取得したイメージの EC-CUBE」が案内にあった版以上かを見る。できれば別のフォルダに作った検証用に本番のバックアップを戻して試す。[ステージングで予行演習](upgrade.md#2-ステージングで予行演習)）、サーバーで `bin/upgrade.sh ~4.3.0 --prod`。サーバーで表示される番号が、パソコンで試したものと同じかを見てから `y`（[バージョンアップ](upgrade.md)）。**`deploy.sh` ではない**。2 つ目の番号が変わる（4.3 → 4.4）ときはプラグインの作り直しが要るので、制作者に相談 | パソコン → サーバー |
| 毎日（自動） | `bin/backup.sh` を cron に。[バックアップ](backup.md) | サーバー |

---

## 困ったとき

**まずこれを打って、出てきた文を読む。**

```bash
bin/plugin.sh doctor
```

たいていはこれで直るか、何が悪いかが日本語で出ます。出た指示に従ってください。

それでも分からないとき:

| 症状 | 見るところ |
|---|---|
| お店が「メンテナンス中」のまま | `bin/plugin.sh doctor`（途中で止まった作業の後始末をします） |
| デプロイが途中で止まった | 出ていた指示どおりに直して、もう一度 `bin/deploy.sh` |
| 直したのに反映されない | サーバーで `bin/plugin.sh reload` |
| 管理画面で直したものを手元にも残したい | `bin/pull-admin-files.sh shop:/srv/myshop` → commit |
| 管理画面で CSS を編集したら消えた | [デザインを直す](install.md#6-デザインを直す) を読む。書く場所が 2 つある |
| データを戻したい | `bin/restore.sh backups/<日時>`（[バックアップ](backup.md)） |

---

## 絶対に打たないコマンド

| コマンド | 何が起きるか |
|---|---|
| `bin/reset.sh` | **データベースと画像が消える。** 戻せない |
| `bin/switch-version.sh` | 同じ。開発でしか使わない |
| `docker compose down -v` | 同じ。`-v` が付いていたら打たない |
| `sudo` 付きの `bin/console` | 全ページが壊れる。`bin/console.sh` を使う |

本番のサーバーで打とうとすると止まるようになっていますが、止まるのを当てにしないでください。

---

## よく使うコマンド（一覧）

```bash
bin/deploy.sh              # 反映する（毎日これ）
bin/plugin.sh doctor       # 困ったらこれ
bin/plugin.sh reload       # 反映されないときこれ
bin/backup.sh              # 退避
bin/restore.sh <退避先>     # 戻す
bin/pull-admin-files.sh <host:path>  # 管理画面で直した分を手元へ
bin/self-update.sh --check # この仕組みの新しい版があるか
bin/console.sh <cmd>       # EC-CUBE のコマンドを打つ
bin/shell.sh               # コンテナの中に入る
```

---

[← README へ戻る](../README.md)
