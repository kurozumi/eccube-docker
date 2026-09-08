# 本番デプロイ

どのサーバーでも同じ手順で公開する。**すでに動いている本番を上げる場合は [バージョンアップ](upgrade.md)。**


すでに動いている本番を**新しいバージョンへ上げる**場合は、この節ではなく
「[バージョン切替 / バージョンアップ](upgrade.md)」を見ること。
`bin/publish.sh` は起動するだけで、本体コードの入れ替えと migration は行わない。


## サーバーを整える（手元から）

```bash
bin/bootstrap-server.sh user@host /srv/myshop      # Docker を入れ、店のファイルを送り、.env を作る
bin/setup.sh mail --remote=user@host:/srv/myshop   # メール（先に 1 通試す）
bin/publish.sh --remote=user@host:/srv/myshop      # 公開
```

`bootstrap-server.sh` は Ubuntu / Debian の VPS を想定（Docker は get.docker.com の手順で入れる。
sudo が使えること）。**サーバーに git も GitHub の鍵も置かない。** 店のファイルは手元から rsync で
送り、以後の反映も `bin/deploy.sh --remote=…` が手元から送る（**push モード**。サーバーに `.git` が
あれば今までどおり向こうで `git pull` する **pull モード**。`--push` / `--pull` で強制できる）。
push で上書きされたファイルはサーバーの `var/deploy-prev/<日時>/` に残る。

手元の `.env` に `ECCUBE_IMAGE` があればサーバーにも書く（配布イメージを pull するだけで済む。
無いとサーバーで build するので 10 分以上かかる）。

## 誰が・何を・どうやって本番へ出すか

エンジニアが直し、担当者が承認して、本番へ出す。この 3 つを**別の人が別の場所で**やる前提で、
壁を 3 枚置いてある。どれか 1 枚が無くても残りは効く。

```
 エンジニア ──(PR)──▶ GitHub の main ──(git pull)──▶ 担当者の手元 ──(bin/deploy.sh --remote)──▶ 本番
             承認が無いと         main の先頭と同じ           プロジェクト名を打つ
             入らない ①          ものしか送れない ②          記録が残る ③
```

| 壁 | 止めること | 入れ方 | 効く条件 |
|---|---|---|---|
| ① GitHub | main への直接 push、承認無しのマージ、force push、削除 | `bin/setup.sh protect`（手元で 1 回） | **非公開リポジトリは有料プラン**（個人は Pro、組織は Team） |
| ② 手元 | main 以外のブランチ、未コミットの変更、push していないコミットを本番へ送る | 何もしなくて効く（`bin/deploy.sh` に組み込み） | 常に |
| ③ サーバー | 何が出るか見ずに出す、誰が出したか分からない | 何もしなくて効く | 常に（本番構成で動いているとき） |

### ① GitHub: PR と承認が無いと main に入らない

```bash
bin/setup.sh protect      # 担当者の GitHub ユーザー名と、承認の人数を聞く
```

ルールセット（main への PR 必須、CODEOWNERS の承認必須、承認後の push で承認を無効化、
未解決コメントがあるとマージ不可、force push と削除の禁止、**管理者も例外なし**）と
`.github/CODEOWNERS` を入れる。**担当者が自分で作った PR は自分では承認できない**ので、
一人で運用するなら承認の人数を 0 にする（PR は要るが承認は要らない）。

無料プランの非公開リポジトリでは API が 403 を返す。そのときは②③だけになり、
「main へ直接 push しない」は**運用で守る**（エンジニアには PR を出してもらい、
main へ push する権限を持つのは担当者だけ、と決める）。

### ② 手元: main の先頭と完全に同じものしか本番へ送れない

`bin/deploy.sh --remote=…` は、向こうが本番構成で動いていると、送る前にこれを確かめる:

- いまのブランチが `DEPLOY_BRANCH`（既定 `main`。`.env` で変えられる）
- コミットしていない変更が無い
- `origin/main` の先頭と**同じコミット**（push していないコミットが無く、古くもない）

1 つでも違えば**送らない**。エンジニアが自分のブランチや作業中のファイルを本番へ出す道が、
ここで閉じる。サーバーで `git pull` する構成でも、サーバーが main 以外にいれば止まる。

**向こうが本番かどうか判定できないとき（止まっている・初回）は本番として扱う。**
開発・検証サーバー（`compose.prod.yaml` 無しで動いているもの）にはこの検査は掛からず、
ブランチも未コミットの変更も送れる（今までどおり）。

### ③ サーバー: 何が出るかを見せ、プロジェクト名を打たせ、記録する

本番へ出す前に、出るコミットと注意の要るファイルを見せる:

```
[deploy] 出るもの（myshop、本番）:
  コード: 3f2a1c0 → 9b7e4d2（3 コミット）
    9b7e4d2 送料無料の閾値を 5,000 円に
    1c0d8a3 会員登録の確認メールの文面
    77ab019 fix: 商品一覧の並び順
  変わるファイル: 6 件
  ⚠ migration が含まれます。DB の構造が変わります。戻すには backups/ が要ります

  本番に出します。続けるなら、プロジェクト名 myshop を入力してください（それ以外で中止）:
  >
```

`y` ではなく**プロジェクト名を打つ**（`bin/reset.sh` の `CONFIRM_DESTROY` と同じ考え。
指が覚えて通してしまわないように）。打つ前なら何も変わっていない。
非対話（cron や CI）なら `CONFIRM_DEPLOY=<プロジェクト名>`。

**見るだけ**なら `--check`。検査と要約を出して、何も送らず何も変えない:

```bash
bin/deploy.sh --check --remote=shop:/srv/myshop
```

出したものはサーバーの `var/deploy.log` に残る（日時、sha、pull か push か、誰が、結果）:

```
2026-09-08T07:12:03Z  9b7e4d2…  push  taro@example.com@macbook  start
2026-09-08T07:15:41Z  9b7e4d2…  push  taro@example.com@macbook  done
```

### 緊急で main 以外を出す

GitHub が落ちている、レビューを待てない障害対応、など。**記録に残る**形でだけ通す:

```bash
DEPLOY_UNREVIEWED=<プロジェクト名> bin/deploy.sh --remote=shop:/srv/myshop
```

`var/deploy.log` に `UNREVIEWED` と残る。落ち着いたら、出したものを PR にして main へ入れる
（入れないと、次の deploy で main の中身に戻る）。

### 誰に何を渡すか

| 人 | 持つもの | 持たないもの |
|---|---|---|
| エンジニア | リポジトリへの push（ブランチ）、開発・検証サーバーの SSH | **本番の SSH**、main への push（①があれば） |
| 担当者 | main へのマージ（承認）、本番の SSH、`bin/deploy.sh` | |

**本番の SSH を持つ人は、②③を素通りしてファイルを置ける。** ②③は「持っている人が
うっかり出す」ことを止めるもので、「持っている人が故意に出す」ことは止められない。
だから本番の SSH はエンジニアに渡さない。

## 公開方式

```bash
# .env で公開方式を選ぶ（COMPOSE_PROFILES）
bin/publish.sh   # compose.prod.yaml を重ねて起動（配布イメージなら pull、なければ build）
```

| プロファイル | 公開方式 | 開けるポート |
|---|---|---|
| `tunnel` | Cloudflare Tunnel（既定） | なし（outbound のみ） |
| `caddy` | Caddy 自動 HTTPS（Let's Encrypt） | 80 / 443 |
| （未設定） | host nginx / AWS ALB の背後 | なし（127.0.0.1 束縛） |

- **tunnel**: **`bin/setup.sh tunnel`**（トークンを貼る → 繋がるか試す → 通れば `.env` に書く。
  Cloudflare の画面でやることも表示する）。手でやるなら `.env` に `TUNNEL_TOKEN`、ダッシュボードで
  公開ホスト名 → `http://nginx:80`。
- **caddy**: `.env` に `SITE_DOMAIN` を設定し、A レコードをこのサーバーへ向ける。
- **背後配置**: `COMPOSE_PROFILES` を空にすると nginx は `127.0.0.1:8080` のみで待ち受ける。

## メール送信

**Mailpit は開発専用**（`compose.override.yaml` にしか無く、本番構成には居ない）。本番は
**`bin/setup.sh mail`** で設定する（サービスを選んで質問に答える → 1 通試しに送る → 届けば `.env` に書く）。
手で書くなら `.env` の `MAILER_DSN`:

```bash
MAILER_DSN=smtp://user:pass@smtp.example.com:587      # SendGrid / Amazon SES / さくら 等
```

- 未設定だと `null://null` で**注文メール・会員登録・パスワード再発行が黙って破棄**される。
  Mailpit 宛てのままだと本番には居ないホストへ送って失敗する。どちらも画面は正常に見える
- `bin/publish.sh` はこの 2 つを止める（`FORCE_PUBLISH=1` で無視できる）。`bin/plugin.sh doctor` も本番で警告する
- 送信元アドレスは管理画面 → 設定 → 店舗設定 → メール設定。送信ドメインの SPF / DKIM は
  メールサービス側の手順に従う（無いと迷惑メールに入る）

---

[← README へ戻る](../README.md)
