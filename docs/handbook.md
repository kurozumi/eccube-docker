# はじめての人のための手引き

理由は書きません。「なぜ」が知りたくなったら、各所のリンク先を読んでください。
ここは**手を動かすためだけ**の文書です。

---

## 登場するものは 4 つ

```
 あなたのパソコン ──(git push)──▶ GitHub ──(git pull)──▶ サーバー ──▶ お客さんのブラウザ
   直す・試す                  控え              動かす           見る
```

- **あなたのパソコン** … ここで直して、ここで試す
- **GitHub** … 直したものの控え。あなた専用のリポジトリ（非公開）
- **サーバー** … お店が動いている場所。**ここでは直さない。** GitHub から持ってくるだけ
- **お客さんのブラウザ** … 見るだけ

「直す場所」と「動かす場所」を分けるのが、この仕組みの全部です。

---

## 最初に 1 回だけやること

[導入手順](install.md) のとおりに進めてください。終わると、あなたのパソコンとサーバーの
両方で `docker compose ps` を打つと一覧が出て、ブラウザでお店が開きます。

サーバーで打ったコマンドはこれだけのはず:

```bash
git clone <あなたのリポジトリ> myshop && cd myshop
bin/init.sh          # .env を作って起動
bin/publish.sh       # 公開する
```

---

## 毎日やること（3 つ）

### 1. あなたのパソコンで直す

| 直したいもの | 触る場所 |
|---|---|
| 見た目（CSS） | `frontend/scss/customize.scss` → `bin/assets.sh build` |
| 画面の部品（twig） | `app/template/original/` に**直すファイルだけ**置く |
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

終わったら、お店をブラウザで開いて目で確かめます。

---

## ときどきやること

| いつ | 何を |
|---|---|
| 月に 1 回くらい | `bin/self-update.sh --check` … この仕組み自体の新しい版があるか。あれば `bin/self-update.sh` |
| EC-CUBE の新しい版が出たとき | [バージョンアップ](upgrade.md) を読んでから `bin/upgrade.sh`。**`deploy.sh` ではない** |
| 毎日（自動） | `bin/backup.sh` を cron に。[バックアップ](backup.md) |

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
bin/self-update.sh --check # この仕組みの新しい版があるか
bin/console.sh <cmd>       # EC-CUBE のコマンドを打つ
bin/shell.sh               # コンテナの中に入る
```

---

[← README へ戻る](../README.md)
