# ミドルウェアの脆弱性に即日で追いつく

nginx・PHP・DB・Redis などに重大な脆弱性が出たとき、**その日のうちに「直す PR と影響の説明」が
できていて、あとは人がマージしてリリースするだけ**、という状態を作る仕組み。

## 全体の流れ

```
03:00 JST  build-image（毎日）   土台の PHP イメージが変わった組だけ焼き直す（月曜は全部）
04:00 JST  security-scan（毎日） 全イメージを Trivy で調べ、保守期限も見る → 要対応なら Issue
05:00 JST  Dependabot（毎日）    版を固定して書いてあるイメージの版上げ PR
06:00 JST  Claude ルーティン      Issue と PR を読み、うちの構成で効くかを調べ、直す PR と説明を書く
           人                    PR を見てマージ → 必要ならリリース
利用者     bin/deploy.sh          配布イメージもミドルウェアも引き直し、変わったものだけ作り直す
```

| 役割 | 担当 | どこ |
|---|---|---|
| 見つける | GitHub Actions | `.github/workflows/security-scan.yml`・`.github/scripts/security_report.py` |
| 版上げの PR | Dependabot | `.github/dependabot.yml` |
| 判断と説明 | Claude のルーティン（クラウドで毎朝） | 下の「ルーティンの指示」 |
| PHP / Debian のパッチを焼く | GitHub Actions | `.github/workflows/build-image.yml` |
| 利用者のサーバーへ届ける | `bin/deploy.sh` | 「0. イメージ」 |
| マージ・リリース | **人** | CLAUDE.md の開発フロー |

## 何が自動で、何が人か

**自動で届くもの（PR もリリースも要らない）**

- **PHP / Debian のパッチ**: 公式の `php:<版>-fpm-bookworm` が作り直されると、翌朝の build-image が
  その組だけ焼き直し、追跡タグ（`4.3` など）が動く。利用者は `bin/deploy.sh` で受け取る。
- **系列タグのミドルウェア**（`nginx:1.30-alpine`・`redis:7-alpine`・`mariadb:10.6` など）:
  上流が作り直せば、利用者の `bin/deploy.sh` が引き直す。

**人が要るもの（リポジトリを書き換える）**

- 系列そのものの乗り換え（保守が終わった nginx 1.27 → 1.30、MariaDB 10.6 → 10.11 など）
- 版を固定して書いてあるもの（`caddy:2.11.4-alpine`・`cloudflared:2026.8.3`）
- 配布イメージの PHP の版の一覧（`build-image.yml` の matrix と `bin/lib/image.sh`）

これらは Dependabot か Claude のルーティンが PR にし、人がマージしてリリースする。
リリースしたものは、利用者が `bin/self-update.sh` → `bin/deploy.sh` で受け取る。

## 点検の Issue（ラベル `security-scan`）

- 要対応があるあいだ **1 つだけ**開いていて、本文が毎日最新になる。**中身が変わった日だけ**コメントが付く
  （通知はその日だけ来る）。要対応が無くなると閉じる。
- 要対応にするもの: 保守が終わった版・60 日以内に終わる版・修正版のある CRITICAL / HIGH・点検できなかったイメージ。
- 配布イメージ（ec-cube）は OS のパッケージだけを見る。`vendor` は EC-CUBE 本体の lock で、こちらでは触らない。
- **あえて配っている保守終了の版**（例: PHP 8.1。4.2 / 4.3 の対応一覧にあるため）は
  `.github/security-accept.json` に理由と見直し期限を書いて外す。期限を過ぎると、また挙がる。

### 挙がったときの判断

| 状況 | すること |
|---|---|
| 系列タグのイメージで、上流がもう直している | 何もしない（利用者の `deploy.sh` が引き直す）。急ぐなら利用者へ案内 |
| 系列タグのイメージで、上流がまだ直していない | 待つ。Issue は開いたままになる |
| 保守が終わった系列 | 乗り換える PR（設定の書き方が変わっていないか確かめる） |
| 配布イメージの OS パッケージ | 土台が変わっていなくても Debian 側だけ直ることがある。`build-image` を `refresh: true` で手動実行 |
| うちの構成では効かない（使っていないモジュールなど） | 理由を Issue にコメントして、受け入れるなら `security-accept.json` |

**影響の見積もりは、うちの設定を読んで決める。** 2026-11 の nginx（NGINX2Root）では、10 件のうち
同梱の構成で効くのは resolver の 1 件だけだった（HTTP/2・TLS は nginx で受けていない）。
一方、`lb.conf.example` を写して nginx で HTTPS を受けている利用者には、深刻な 2 件が効いた。

## Claude のルーティン

毎朝 06:00 JST にクラウドで動く。止める・変えるのは Claude Code の `/schedule`。

**ルーティンの指示（要約）**

1. ラベル `security-scan` の開いた Issue と、Dependabot の開いた PR を読む
2. 項目ごとに、上の表のどれに当たるかを決める。そのとき `compose*.yaml`・`docker/nginx/*.conf`・
   `docker/caddy/Caddyfile`・`docker/php/*` を読み、**うちの構成で本当に効くか**を書く
3. リポジトリを書き換える必要があるものは、作業ブランチを切って PR を作る。本文には
   影響の表・確かめたこと／確かめていないこと（分けて書く）・リリースノートの下書き
4. Issue に「今日の判断」をコメントする（前日と同じなら書かない）
5. **マージしない・main へ push しない・リリースしない・タグを打たない**

**ルーティンにできないこと**: クラウドの環境で Docker が動くとは限らないので、画面が出るかまでは
確かめられない。PR の「確かめていないこと」に書かせ、人がマージ前に手元で見る。

## 利用者の側

- **追跡タグ（`ECCUBE_IMAGE=…/ec-cube:4.3`）にして `bin/deploy.sh` を回していれば**、PHP・Debian・
  系列タグのミドルウェアのパッチは、上流が直した翌日に入る。
- `bin/deploy.sh` はミドルウェアも引き直す（`docker compose pull --ignore-buildable`）。以前は ec-cube だけで、
  nginx などは最初に引いた日の版のまま残っていた。
- 手元で build している環境は `bin/deploy.sh --rebuild`（docs/deploy.md「PHP のパッチを受け取る」）。
