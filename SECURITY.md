# セキュリティポリシー / Security Policy

脆弱性を見つけたら、**公開の Issue には書かず**、下の窓口へ非公開で知らせてください。
公開の Issue に書くと、直す前に全利用者の本番サイトが危険にさらされます。

## 報告先

| 窓口 | 使いどころ |
|---|---|
| **[GitHub の非公開報告](https://github.com/kurozumi/eccube-docker/security/advisories/new)**（推奨） | GitHub アカウントがある。修正までのやり取りをそのまま advisory に残せる |
| メール **info@a-zumi.net** | GitHub を使えない。件名に `[security] eccube-docker` と入れてください |

英語・日本語どちらでも構いません。

## 書いてほしいこと

うまく書けなくて構いません。分かる範囲で:

- 何が起きるか（何が読める・書ける・実行できるか）
- 再現の手順。コマンドと出力をそのまま貼ってください
- 影響を受ける版（`VERSION` の中身、または Release のタグ）と、`.env` の `ECCUBE_VERSION` / `ECCUBE_IMAGE`
- 分かれば、原因だと思う箇所（`bin/*.sh` / `docker/` / `compose*.yaml` / `.github/workflows/` のどれか）

## この環境が対象にするもの、しないもの

**対象（このリポジトリで直す）**

- `bin/` のスクリプト（`deploy.sh` / `self-update.sh` / `backup.sh` / `restore.sh` など。
  これらはサーバーで root 相当の権限で動くものです）
- `docker/` の Dockerfile・entrypoint・php.ini・nginx / Caddy の設定
- `compose*.yaml` と `.env.example` の既定値（意図せず公開されるポート、弱い既定値など）
- `.github/workflows/`（イメージの焼き方、リリースの添付と署名、Pages）
- `app/config/eccube/packages/` と `optional/` に置いた framework 級設定

**対象外（別のところへ）**

- **EC-CUBE 本体**の脆弱性 → [IPA の脆弱性関連情報の届出](https://www.ipa.go.jp/security/todokede/vuln/uketsuke.html)へ
  （EC-CUBE の脆弱性はこの経路で JVN として公表されています。既知のものは
  [EC-CUBE の脆弱性一覧](https://www.ec-cube.net/info/weakness/)）。
  この環境は本体を一切改変しておらず、ビルド時に Packagist から取っています。
  本体のパッチが出たら、この環境では `bin/upgrade.sh` で当てられます
- **PHP / Debian / MariaDB / PostgreSQL / Redis** のイメージ自体の脆弱性 → 各上流へ。
  この環境のイメージは**毎週月曜に土台から焼き直し**、OS と PHP のパッチを取り込みます。
  重大なものは `build-image.yml` の手動実行（`refresh: true`）で当日焼きます
- 利用者が `app/Customize` / `app/Plugin` / `app/template` に置いたコードとプラグイン
- 利用者のサーバーの設定（SSH、ファイアウォール、`.env` の管理）

判断に迷うものは、とりあえずこちらへ送ってください。違うところなら案内します。

## 対応する版

| 版 | 対応 |
|---|---|
| 最新の Release（`1.0.x` の最新） | 直す |
| それより古い `1.0.x` | 直さない。`bin/self-update.sh` で最新へ上げてください（環境のコードだけが更新され、店のデータとコードには触りません） |

## 受け取ったあと

- **3 営業日以内**に受け取った旨を返します
- 内容を確かめ、深刻度と直す見込みを伝えます。個人で運営しているので、直すまでの時間は内容と手の空き具合で変わります
- 直したら Release を出し、リリースノートと GitHub Security Advisory に載せます。
  報告者の名前は、希望があれば載せます（載せないのも選べます）
- 修正が Release に出るまでは、内容を公開しないでください。**90 日**を目安にし、
  それまでに直せないときはこちらから相談します

## 利用者へ: 直った版の受け取り方

```bash
bin/self-update.sh --check     # 新しい版があるか
bin/self-update.sh             # 環境のコードを更新（.env と店のコードは触らない）
docker compose up -d           # entrypoint や設定が変わっていれば作り直し
```

イメージ（PHP / OS）のパッチは `bin/deploy.sh` が追跡タグを引き直して当てます。
本体のパッチは `bin/upgrade.sh <制約> --prod`。詳細は `docs/upgrade.md` と `docs/distribute.md`。

---

## English

Please **do not open a public issue** for security problems. Report privately via
[GitHub private vulnerability reporting](https://github.com/kurozumi/eccube-docker/security/advisories/new)
(preferred) or email **info@a-zumi.net** with `[security] eccube-docker` in the subject.

**In scope**: the scripts under `bin/`, everything under `docker/`, the `compose*.yaml` files and
`.env.example` defaults, the GitHub workflows, and the framework-level config under `app/config/`.

**Out of scope**: EC-CUBE itself (report through [IPA's vulnerability reporting](https://www.ipa.go.jp/security/todokede/vuln/uketsuke.html),
the route EC-CUBE advisories are published through as JVN; this project ships it unmodified), the upstream PHP / Debian / database / Redis images
(our images are rebuilt from the base every Monday), and code that users put in `app/`.

Only the latest release is supported. You will get an acknowledgement within 3 business days.
Please allow up to 90 days before public disclosure; we will tell you if we need longer.
