# AGENTS.md — この場所で作業する AI へ

ここは **EC-CUBE 4 のお店を Docker で動かすための環境**（eccube-docker）です。お店のコードは
このリポジトリに、EC-CUBE 本体はイメージの中にあります。**本体（`/var/www/html` の `src/` や
`vendor/`）は編集しません。** 直す場所は `app/`（PHP・テンプレート・プラグイン）と `html/user_data/`
（CSS / JS）だけです。

## まず読むもの

- `docs/handbook.md` … 手順だけ。毎日の 3 コマンドと困ったときの 1 コマンド
- `docs/install.md` … 初回の導入から公開まで
- 迷ったら `bin/<コマンド>.sh --help`（全部のコマンドが自分の説明を出します）

## 初回

```bash
bin/init.sh            # これだけ。.env を作り、パスワード類を生成し、空いているポートを選び、起動して、終わるまで待つ（初回は数分）
```

終わると **お店の URL・管理画面の URL（`admin-<乱数>`）・ログイン ID・パスワード** が表示される
（`.env` にも入っている）。ポートは 8080 が使われていれば自動で別の番号になるので、
表示された URL を使う。Docker が無い・動いていないときは、その旨と入れ方が表示される。

## 毎日

```bash
bin/plugin.sh doctor                     # おかしいときは、まずこれ（日本語で理由が出る）
git add <直したファイル> && git commit && git push   # 控えを送る（git add -A は使わない: 店のデータが混ざる）
bin/deploy.sh --remote=<host>:<path>     # サーバーに反映（退避 → メンテ ON → pull → migration → 確認 → OFF）
```

## 公開（本番）

メールは `bin/setup.sh mail`（質問に答える → 試しに送る → 通れば .env に書く。人に答えてもらう）、
DB を外に出すなら `bin/setup.sh db`。`.env` に `TUNNEL_TOKEN`（Cloudflare Tunnel）を書いてから
`bin/publish.sh`。既定のパスワード・管理者が `password` のまま・メール未設定なら**止まります**。
それは正しい挙動です。無理に通さないでください（`FORCE_PUBLISH=1` は人が決めること）。

## 絶対にやらないこと

- **本番で `bin/reset.sh`・`bin/switch-version.sh`・`docker compose down -v` を打たない。**
  DB・画像・セッションが消え、戻せません。上げたいだけなら `bin/upgrade.sh <制約> --prod`
- **`.env` と `.env.app` を git に入れない**（全パスワードの鍵 `ECCUBE_AUTH_MAGIC` が入っている）
- **`bin/publish.sh` / `bin/upgrade.sh` / `bin/restore.sh` / `bin/self-update.sh` を人の確認なしに実行しない。**
  外に出る・データを入れ替える操作です。確認プロンプトに自動で y を流さない
- **`app/template/` に本体のテンプレートを丸ごと写さない。** 直すファイルだけ置く
  （丸ごと写すと本体を上げても古いほうが勝ち続ける）
- キャッシュの組み立て（`bin/plugin.sh reload` / `doctor`）を途中で止めない。全ページ 500 になる
- 出力が長いコマンドをパイプで切らない（`| tail` 等）。コンテナの中の php が止まる

## 分からないとき

`docs/` に全部あります（`customize.md` 直す場所、`upgrade.md` 上げ方、`backup.md` 控え、
`data-safety.md` 消える操作、`deploy.md` 公開、`scale.md` 大きくするとき）。
`CLAUDE.md` は **この環境自体を保守する人向け**の細かい記録で、お店の運用には要りません。
