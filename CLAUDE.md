# CLAUDE.md

> **お店を運用する人（とその AI）へ: まず `AGENTS.md` を読んでください。** このファイルは
> eccube-docker という環境**そのもの**を保守するための記録で、お店の日々の運用には要りません。

EC-CUBE 4 の汎用 Docker 環境。本体はイメージにベイクし、`app/`（Customize / template /
DoctrineMigrations / config / Plugin）と `html/user_data`（独自 CSS/JS）、`frontend`（scss
ソース）だけを bind-mount して Git 管理する。

## 原則

- **EC-CUBE 本体を直接編集しない**。用途ごとの置き場所:
  - PHP カスタマイズ（Controller/Entity/Form/Service/Event/Twig拡張/Command）→ `app/Customize/`
  - テンプレート上書き → `app/template/`
  - スキーマ変更（migration）→ `app/DoctrineMigrations/`
  - プラグイン（開発・ストア導入）→ `app/Plugin/`（mount 済み・Git 管理）
  - 独自 CSS/JS → `html/user_data/assets/{css,js}`。本体 `default_frame.twig` が
    `customize.css` / `customize.js` を自動読込する（上書き Twig 不要）。scss ソースは
    `frontend/scss/`、ビルドは `bin/assets.sh`。
    **ビルド先は `customize-theme.css`。`customize.css` へ書き出さない。**
    あちらは管理画面（コンテンツ管理 → CSS 管理）が `dumpFile` で直接書き換える
    ファイルで、同じ場所へビルドすると**店が画面から入れた CSS がビルドのたびに
    黙って消える**。`customize.css` 先頭の `@import` がテーマを読み込む。
    **その `@import` を消さない／上に何も書かない**（先頭以外の `@import` は
    CSS の仕様で無効になり、テーマが丸ごと効かなくなる）。
  - **`html/template/original/assets` と `.base` は eccube-docker では追跡しない。** 店ごとの
  成果物で、tag からの tarball（＝配布物）にそのまま入るため。一度コミットして
  6MB・125 ファイルの 4.4-dev の写しを全利用者に配りかけた。手元の無視は
  `.git/info/exclude`（`.gitignore` に書くと利用者の `git add` まで黙って落ちる）。
- **オリジナルテーマ（コード `original` 固定）は twig と静的物で正反対。** twig は
    `app/template/original/` に直すファイルだけ（フォールバックあり）。静的物は
    `html/template/original/assets/` に**丸ごと**（`asset()` の base_path は 1 本で
    フォールバック無し。1 ファイル欠けると 404）。`bin/theme.sh init` が本体から写し、
    `.base` に版と sha256 を記録。**写しはフォールバック無しで勝ち続ける**ので、
    `bin/upgrade.sh` の最後に `theme.sh diff` で本体側の変更を出す。
    テーマの選択は `.env` の `ECCUBE_TEMPLATE_CODE`（管理画面の選択はコンテナ内 `.env` に
    書かれ、upgrade で消える）。
  - **本体テーマの twig / scss はホストに無い。** `bin/ide-sync.sh` が参照用の写しを
    `.ide/` に作る（twig は `src/Eccube/Resource/template/`、scss は
    `html/template/default/assets/scss/`）。**写しを編集しても反映されない。**
- **`app/template/` に本体のテンプレートを丸ごと写さない。** 写した瞬間は同じでも、
  本体を上げたときに**古いほうが勝ち続ける**。例外は出ず、直したはずの不具合が
  戻る・新しい項目が出ない、という形で出る。上書きするのは**直すファイルだけ**に
  すること。実際にこのリポジトリには本体と同一の写しが56件あった（末尾の改行しか
  違わなかった）ので消した。
- **プラグインはテーマへ何も写さない**（2026-09、11プラグイン）。`dtb_page.file_name`
  も `dtb_mail_template.file_name` もプラグインの中を指す。Twig のローダーの探索先に
  `app/Plugin` が入っているので、写さなくても読める。**テーマを変えても写し直しが
  要らない。** `app/template/default/` は **`.gitkeep` だけ**で、ここにファイルが
  増えていたら店が自分で置いた上書きテンプレート。
  店がテンプレートを直すのは**プラグインテンプレート編集プラグイン**の役目で、
  直した内容はデータベースに残る。ページ管理とメール設定の本文欄は伏せてあり、
  本体がそれでもテーマへ書いた写しは、あちらがその場で消す（本体は読むのを
  ローダーに任せるが、**書くのは必ずテーマ配下**）。
- **ライセンスは Apache-2.0**（`LICENSE`）。商用・受託・再配布とも自由。
  **EC-CUBE 本体は対象外**（ここには含まれず、ビルド時に Packagist から取る。
  本体を一切改変していないので、イメージ内の EC-CUBE は EC-CUBE 自身のライセンス）。
- **バージョンは `.env` の `ECCUBE_VERSION`**（build-arg）。切替は `bin/switch-version.sh`。
  ただし **`.env` に `ECCUBE_IMAGE` があるときは build しないので、この値は使われない。**
  動くのはタグに焼かれたバージョンで、両者は簡単にずれる。`bin/upgrade.sh` は pull した
  イメージの実バージョンを表示して確認を求める。
- **配布イメージは毎日、土台が変わった組だけ焼き直される（月曜は全部）**（`build-image.yml` の `schedule`）。
  土台の digest は焼いたイメージのラベル `org.opencontainers.image.base.digest` に残し、翌朝それと上流を比べる。土台の
  `php:8.x-fpm-bookworm` は浮動タグなので、**焼き直すだけで PHP と Debian のパッチが入る。**
  焼くのは**最新リリースのタグ**の Dockerfile（main を焼くと未リリースの変更が配られる）、
  **キャッシュ無し**（apt の layer が当たるとパッチが入らず、焼いた意味が無い）。
  追跡タグ（`4.3` / `4.3-php8.3`）と日付タグ（`4.3-20260907`）だけ動かし、`-vX.Y.Z` は
  「そのリリースの時点」として不変。**本番の推奨は追跡タグ + `bin/deploy.sh`**
  （PHP のパッチに `upgrade.sh` は要らない。PHP は `eccube_app` ボリュームの外）。
  **`deploy.sh` はイメージを ID で比べる。タグ名で比べない。** 追跡タグは焼き直しても名前が
  変わらないので、v1.0.12 まではタグ名の比較で「同じ」と判定し、一度も引き直していなかった
  （CVE-2026-109618/109619 の緊急焼き直しが届かずに発覚）。ローカル build の環境は焼き直しを
  受け取れないので `deploy.sh --rebuild`（docs/deploy.md「PHP のパッチを受け取る」）。
  緊急は `workflow_dispatch` の `refresh: true` で当日焼く。
- **ミドルウェアの脆弱性と Docker の設定は「毎日の点検 → PR → 人がマージ」で追う**（`docs/security-updates.md`）。
  設定の決まり（固め・公開範囲・秘密の渡し方・ヘッダ）は `.github/scripts/config_check.py` が展開後の compose で見て、
  compose / docker/ を変える PR を `config-check.yml` が落とす。**決まりを変えたら、このファイルとあちらを揃える。**
  `security-scan.yml` が全イメージを Trivy と保守期限（endoflife.date）で調べ、要対応ならラベル
  `security-scan` の Issue を 1 つ開く。判断と PR は人（手元の Claude Code に Issue を渡してよい。定期のルーティンは費用の都合で止めてある）。**マージとリリースは人。**
  **系列タグ（`nginx:1.30-alpine`）は名前が変わらないので、引き直さない限り古いまま。**
  `bin/deploy.sh` は v1.0.16 まで ec-cube しか pull しておらず、nginx は最初に引いた日の版で
  止まっていた。いまは `pull --ignore-buildable` で全部引き直す。
  **保守が終わった系列はタグを追っても直らない**（`nginx:1.27-alpine` は 2025-04 から作り直されず、
  NGINX2Root の修正が届かなかった）。あえて配る保守終了の版は `.github/security-accept.json` の `accept` に理由と期限を書く。
  **上流がまだ直していない CVE は `vuln` に、イメージ・パッケージ・番号で並べて期限付きで受け入れる**（番号に無い CVE や
  期限切れはまた挙がる）。`compose.override.yaml` にだけ出てくる開発用のイメージは「参考」に回す。
- **Dockerfile の `apt-get upgrade` を外さない。** 土台の `php:8.1` は EOL で二度と焼き直されず、
  upgrade 無しだと Debian の修正済み CVE が数百件残ったまま毎週配ることになる（v1.0.3 の Trivy）。
  vendor の advisories（twig / composer / symfony、4.2・4.3 で 31 件）は EC-CUBE 側の lock で、
  こちらでは触らない（本体無改造の原則）。
- **Dockerfile が変わっていないリリースは焼かない**（`build-image.yml` の `retag`）。前のタグから
  `docker/php/**` とワークフローに差分が無ければ、追跡タグ `<系列>-php<版>` に `-vX.Y.Z` を足すだけ
  （`imagetools create`。来歴・SBOM も付いたまま）。追跡タグ自体は動かさない。
- **PHP は系列ごとに複数焼く**（4.2: 8.1/8.2、4.3: 8.1/8.2/8.3、4.4: 8.2〜8.5。上流 README の
  対応一覧）。`-php` 無しの短いタグは系列の既定（`image_php_for_series`）。phpredis は系列で
  決まる（4.2/4.3: 6.0.2、4.4: 6.3.0）。**matrix と `bin/lib/image.sh` を揃える。**
  **既定（matrix の `default: true`）を動かすと、短いタグを追っている本番の PHP が次の焼き直しで
  黙って変わる。** 定期の焼き直しは main のワークフローで回るので、リリースを待たずマージした時点で
  効く。4.3 の既定を 8.2 → 8.3 にしたのは 8.2 のサポート切れ（2026-12-31）のため。
  `upgrade.sh` / `switch-version.sh` は `--php=<版>` を受け、系列が対応しない版なら何も変えずに止まる
  （`image_resolve_php`）。いまの PHP は**イメージの** `ENV PHP_VERSION` から読む（コンテナの環境変数は
  env_file 経由で .env の値が混ざるので見ない）。
- **本体の作りに触る変更は、配っている全部の系列（4.2・4.3・4.4）で確かめる。1 つの系列で確かめて全部に効かせない。**
  同じ名前の設定・クラスでも、系列で中身が違う。実例: #133 は 4.4 のイメージだけを見て、Redis のセッションの
  `SameSiteNoneCompatSessionHandler` の包みを全部の系列で外した。4.4 にはそのクラスが無いが、4.2 / 4.3 はそれが Cookie の
  SameSite=None・Secure・パスを付けていたので、**決済の戻りでセッションが届かなくなった**（#228 で包み直す）。
  確かめる順は 3 つ。
  1. **公式ドキュメント**（https://doc4.ec-cube.net/ ）で、本体が想定している作りを知る。
  2. **全部の系列のソース**（`docker run --rm --entrypoint sh <イメージ> -c '<読むコマンド>'` か `raw.githubusercontent.com/EC-CUBE/ec-cube/<系列>/…`）で、
     いまもそうかを見る。**設定ファイルは最後まで読む**（`sed -n '/session:/,/cookie_httponly/p'` のように途中で切ったせいで、
     4.4 の `cookie_samesite: none` を見落とし「4.4 は Lax」と書いた）。
  3. **全部の系列で動かす。** 読むだけでは分からないことがある。
  **公式ドキュメントも系列に追いついていないことがある。** session_handler_settings の例は、4.3 では例外で起動せず
  （4.3 の `SameSiteNoneCompatSessionHandler` は親のコンストラクタで Symfony のハンドラを拒む）、4.4 ではクラスが無く、
  MySQL の表（`sess_lifetime MEDIUMINT`）は 4.2 以降で保存できなかった（どれも動かして確かめた。2026-11-21）。
  ドキュメントは「想定」として読み、事実はソースと動かした結果で決める。
- **`image_check_version` は alpha / beta / RC を安定版として数えない。** 以前は「系列で始まる版が
  あるか」だけを見ていたので、4.4.0-alpha が Packagist に出た時点で `~4.4.0` を通し、build に入って
  から composer が落ちていた（create-project は stability を指定しないので安定版しか探さない）。
  DB の版は `.env` の `MARIADB_VERSION` / `PG_VERSION`（image と Doctrine の `serverVersion` の
  両方に効く。`DATABASE_SERVER_VERSION` は外部 DB で版が違うときだけ）。
  **MariaDB の既定は v1.0.17 で 10.6 → 10.11**（10.6 は 2026-07 で保守終了）。`init.sh` は `.env` に版を
  書かないので、既定を動かすと既存の環境は次の `up` で**データごと新しい版へ上がる**（`MARIADB_AUTO_UPGRADE`
  が mariadb-upgrade を流す。下げる方向には戻せない）。既定を動かすときはリリースノートで backup を案内する。
  外部 DB で版を書いていない環境は、Doctrine に伝える版だけが 10.11 に変わる（実物が違えば `DATABASE_SERVER_VERSION`）。
- **`bin/self-update.sh` の更新対象は `.eccube-docker-paths`。** スクリプト内の配列は控えで、
  **正は「これから入れる版」の一覧**。スクリプト側だけ見ると、新しい版で足したパスが
  初回の更新で届かない（`LICENSE` を足したときに実際にそうなった）。
  **リリースの添付（`eccube-docker-<ver>.tar.gz` / `SHA256SUMS` / attestation）を取り、sha256 と
  署名を確かめてから展開する**（`release-assets.yml` が publish 時に付ける。#120）。添付の
  無いリリースは codeload に落ちて「検証なし」と出す。
  **書き換える前に、書き換える・消すファイルを `var/self-update/<日時>-from-<版>/before.tar` に控え**（`--force` で
  上書きする店の変更もここに残る）、新しいファイルは同じディスクの置き場へ先に全部写してから `mv` で 1 つずつ入れ替える。
  入れ替えの途中の失敗・Ctrl-C は `undo_apply` が控えから戻す。
  **`mapfile` を使わないこと。** bash 4 以降の組み込みで、**macOS の bash は 3.2**。
  `command not found` で `set -e` が働き、何も出さずに死ぬ。
- **「更新」は 3 つあり、別物。** 自分のコードは `bin/deploy.sh`（毎日）、環境（`bin/` や
  compose）は `bin/self-update.sh`、EC-CUBE 本体は `bin/upgrade.sh`。順番は
  self-update → upgrade。逆にすると新しい本体を古いスクリプトで扱うことになる。
  `deploy.sh` はボリュームを作り直さず DB も画像も触らない。**`up -d` は bind mount の設定ファイルの変更では
  作り直さない**ので、nginx / caddy は設定の指紋（`var/deploy-conf/`）が違えば `nginx -t` / `caddy validate` の
  あとで再起動する（v1.0.18 のキャッシュの直しが deploy で効かなかった）。DB は再起動せず注意だけ。メンテナンス表示は
  `deploy:<token>` で立て、失敗したら **OFF にしない**（`doctor` が後始末する）。
  詳細は `docs/distribute.md`。
- **起動系のスクリプトに `up -d --build` を直接書かない。** 配布イメージを使っている
  利用者の環境では、pull したイメージをローカル build で上書きしてしまう。
  build と pull の判定は `bin/lib/image.sh` の `image_provision` に寄せてある。
- **マイナー（4.4 → 4.5）はプラグイン全数の移植を伴う。** パッチ（4.4.1 → 4.4.2）は
  `upgrade.sh` だけで済む。マイナーでは対象版ごとの保守ブランチを切り、コード名・
  パッケージ名・version を置換し、**CI の matrix にも新版を足す**（いまは全プラグインが
  `4.4` 固定で、足さないと新版で一度も検証されない）。**黙って壊れる型が3つある**
  （目印による差し込み・本体の処理への割り込み・本体の副作用への対処）。
  詳細は `docs/upgrade.md`。
- **`app/template` は本番でも rw。** 管理画面（ページ管理・ブロック管理・メール設定の本文）が
  ここに書く。ro だとブロックと新規ページの保存が 500、メール本文は保存エラー（本体は
  `dumpFile` を捕まえていない）。開発では override が rw にしていたので気づかなかった。
  コードの側（`app/Customize` 等）は ro のまま。
- **Linux の本番は `.env` に `PUID` / `PGID`。** entrypoint が www-data の uid を揃える。
  揃えないと、管理画面が書いたファイルを `git pull` が上書きできず、ホストが置いた
  ファイルを管理画面が書けない（欄が空に見える）。macOS は透過なので不要。
- **ディスクに残る状態は、git か backup のどちらかに必ず入る。** 管理画面は DB
  だけでなくファイルにも書く（CSS/JS 管理 → `html/user_data/assets/{css,js}`、
  ページ管理 → `app/template/user_data/`、ブロック管理 → `app/template/<テーマ>/Block/`、
  テーマ切替・セキュリティ設定 → **コンテナ内** `/var/www/html/.env`）。
  `app/template/user_data/` は以前 .gitignore していたが、`dtb_page` の行と対なので
  **DB だけ持って引っ越すとそのページが 500 になる**。追跡に戻した。
  `bin/backup.sh` は 5 点セット（DB / 画像 / 管理画面が書いたファイル＋git に入らない資産 /
  コンテナ内 .env / **ホストの .env**）。`admin-files.tar.gz` は `html/user_data` 全体と
  `app/Plugin`（`.git` 抜き。remote は `plugins.txt`）を含む。favicon・納品書ロゴ・買った
  プラグインは git に無いので、ここでしか運ばれない。
  **`ECCUBE_AUTH_MAGIC` は全パスワードのハッシュの鍵。** 違う値で DB を戻すと誰も
  ログインできず、エラーも出ない。`restore.sh` が DB を戻す前に突き合わせて止める。
  引っ越しは「clone → `bin/init.sh` → AUTH_MAGIC を合わせる → `bin/restore.sh`」。
  **消す・書き換えるコマンドは、先に退避して、退避できなければ始めない。失敗したら退避から戻す。**
  `restore.sh` は戻す前にいまの状態を `backups/<日時>-before-restore/` へ取り（`BACKUP_LABEL`）、
  メンテナンス表示の中で戻し、途中で失敗したら `--rollback` でそこから戻す。**ダンプは完了の行
  （`-- Dump completed` / `-- PostgreSQL database dump complete`）があるかを先に見る。** 途中で切れた
  ダンプを psql に流すと、入力の終わりを正常な終わりとみなし、空の表のまま 0 で終わる（1 つの
  トランザクションでも防げない。試験で踏んだ）。`plugin.sh remove` も退避 → uninstall（失敗したら
  止まる）→ フォルダは `var/removed-plugins/` へ移す。`backup.sh` の世代管理は自分が付けた名前だけを
  数え、`-before-` の控えは別勘定（`BACKUP_KEEP_SAFETY`）、`BACKUP_PROTECT` は数から外す。
  **DB は MariaDB / MySQL か PostgreSQL**（`.env` の `DB_ENGINE`。イメージは両方の拡張を持つ）。
  backup / restore はそれを見て mysqldump / pg_dump を使い分ける。外部 DB でも同じ
  （`db` サービスが無ければ同じ DB のクライアントを使い捨てコンテナで起動し `.env` の `DB_*` で繋ぐ）。
  **ダンプは種類をまたいで戻らない**ので、引っ越し先も同じ `DB_ENGINE` にする。
  **`BACKUP_SYNC`** で外へ送る。送れなければ失敗にする（黙って飛ばすと「取れているつもり」になる）。
  **`BACKUP_ENCRYPT_KEY`** があれば全ファイルを AES-256 で暗号化して平文を残さない（DB ダンプは
  個人情報そのもの。#118）。`restore.sh` は `.enc` を見て同じ鍵で復号する。鍵を失うと全世代が
  読めなくなるので、鍵は `.env` とパスワードマネージャの両方に。
  **本番で管理画面が書いたファイルはそのサーバーにしか無い。** `doctor` と `backup.sh` が
  未コミット分を挙げる。
- **`.env` はアプリのコンテナに丸ごと渡さない。** 渡るのは `compose.yaml` の
  `x-eccube-environment` に列挙したものだけ（`DB_ROOT_PASSWORD` / `TUNNEL_TOKEN` /
  `BACKUP_SYNC` をアプリに乗せないため。#107）。EC-CUBE の任意設定は `.env.app`
  （`env_file` の `required: false`）。**空文字を `environment` で注入しない**
  （Symfony Dotenv が「設定済み」と見て本体の既定値を潰す）ので、任意のものは
  列挙せず `.env.app` に逃がす。`DB_PASSWORD` / `DB_ROOT_PASSWORD` / `ECCUBE_AUTH_MAGIC`
  は `:?` で必須（既定値 `eccube_pass` で黙って立ち上がらない。#110）。
- **`bin/reset.sh` と `bin/switch-version.sh` は `down -v` する。** DB・画像・
  セッションが消える。**消す前に `backups/<日時>-before-<名前>/` へ退避し、取れなければ何も消さずに止まる**
  （`guard_backup_before_destroy`。止まっているスタックは DB に繋がらず取れないので止まる。取らずに消すのは
  `DESTROY_WITHOUT_BACKUP=<プロジェクト名>`）。`deploy.sh` も**メンテナンス表示を立ててから**退避する。 稼働中が本番構成なら
  `CONFIRM_DESTROY=<プロジェクト名>` が無いと止まる（`bin/lib/guard.sh`）。
  **停止中は判定できない**ので、止まっている本番で打てば消える。
  上げたいだけなら `upgrade.sh`。詳細は `docs/data-safety.md`。
- **本番には `main` の先頭と同じものしか出ない。** `bin/deploy.sh` は向こうが本番構成なら、
  手元がブランチ違い・未コミット・未 push のどれかで**送らない**（`bin/lib/deploy-guard.sh`）。
  出る前に要約を見せて**プロジェクト名を打たせる**（`y` では通さない）。非対話は
  `CONFIRM_DEPLOY=<名前>`、緊急の main 以外は `DEPLOY_UNREVIEWED=<名前>`（`var/deploy.log` に残る）。
  向こうが**止まっていて判定できないときは本番として扱う**（guard.sh と同じ）。開発/検証サーバーには
  掛からない。GitHub 側の PR 必須・承認必須は `bin/setup.sh protect`（**非公開リポジトリは有料プラン**が
  要る。無料なら 403 で止まり、手元とサーバーの壁だけになる）。詳細は `docs/deploy.md`。
- **起動時の migration は、未適用が確かにあるときだけ、DB を取ってから流す。** entrypoint は DB に繋がるかと
  `doctrine:migrations:up-to-date` の出力（`Out-of-date`）で見る。**確かめられない（DB が起きていない・コンソールが
  起動しない）ときは何もしない**（メンテナンスにもしない。次の起動でまた見る）。`deploy.sh` の最中（`deploy:` の表示）も
  流さない（deploy が退避してから流す。同時に流すと二重に当たる）。未適用があれば `var/migrate-backup/` へダンプしてから
  流し、成功したらダンプは消す。取れない・失敗したらメンテナンス表示（`entrypoint:`）にして止める。表示は、後の起動で
  未適用が無くなっていれば entrypoint が外し、`deploy.sh` の成功でも外れる（`doctor` は外さない）。
  **イメージの `pg_dump` は Debian の 15 で、16 以上のサーバーは取れない**（取れない側に倒れてメンテナンスになる。
  PostgreSQL は deploy.sh で反映する）。**entrypoint は `/bin/sh`（dash）で `pipefail` が無い。**
  **メンテナンス表示はそのホストのボリュームにしか無い**ので、複数ホストのアプリホストは守れない。
- **`bin/upgrade.sh` は失敗したら自動で元の版に戻す。** 止める前に `.env` を `var/upgrade/env.before` へ写し、
  動いているイメージの ID を控え、**メンテナンス表示の中で**バックアップ（`-before-upgrade`）を取り、本体ボリュームを
  `<プロジェクト>_eccube_app_before_upgrade` へ写す。新しい版のボリュームにも表示を置いて起動し、token の cookie で
  中から開くかを見てから外す（確認前に注文が入って、戻したときに消えないように）。失敗・Ctrl-C は `rollback_upgrade` が
  .env・タグ・本体を戻し、DB に書いていれば `restore.sh --rollback --db-only` で戻して、**`ECCUBE_SKIP_DB_INIT=1` で**
  起動し直す（entrypoint の migration は失敗を握るので、失敗した独自 migration をもう一度当てて戻した DB を書き換える）。
  差分の検査は削除に加えて**列の名前の変更**（`CHANGE a b` / `RENAME COLUMN`）も止める。
  **pipefail の下で `docker compose … | grep -q` を書かない。** grep が先に終わると compose が SIGPIPE で落ち、
  一致したのに「無い」になる（切り戻しが DB を起こさずに戻そうとして失敗した。5 回に 2 回）。変数に取ってから見る。
- **本番を上げるときは `bin/upgrade.sh <制約> --prod`。** `--prod` を落とすと
  `compose.override.yaml`（開発用のポートと bind mount）が効いた状態で公開される。
  **画面は出るので気づきにくい。** 稼働中なら自動でも寄せるが、停止中に打つと効かない。
- **compose ファイルの並びは `.env` の `COMPOSE_FILE` が正。`-f` を直書きしない。**
  PostgreSQL（`DB_ENGINE=postgresql`）は `compose.postgresql.yaml` を重ねる必要があり、
  `bin/init.sh` がそれを `COMPOSE_FILE` に書く。`docker compose -f a -f b` と直書きすると
  **`COMPOSE_FILE` は無視される**ので、その場所だけ MariaDB が立つ。**本番だけそうなっていた**
  （`upgrade` / `publish` / `deploy` が直書きだった）。`bin/lib/compose.sh` の
  `compose_files [--prod]` が `.env` の並びを読んで prod の出し入れだけをする。
- **IDE がライブラリを未定義と言うのは正常。** 本体と `vendor` はボリュームの中だけにあり
  ホストには1ファイルも無い。`bin/ide-sync.sh` で `.ide/` へ写し、PhpStorm の
  **Include Path**（ソースルートではない）に足す。リモートインタプリタを設定しても
  解決しない。バージョンを切り替えたら写し直す。
- **外部ライブラリは `app/Customize/composer.extra.json`（git 管理）に宣言する。**
  `composer.json` と `vendor` は `eccube_app` ボリュームの中にあり、git にも backup にも
  入らない。`bin/upgrade.sh` はこのボリュームを作り直すので、コンテナの中で
  `composer require` しただけのライブラリは**黙って消える**（使っているコードが
  「Class not found」で落ちるまで気づけない）。entrypoint が起動時に、宣言のうち
  `vendor` に無いものだけを入れる。`upgrade.sh` は消える前に列挙して確認を求める。
- **framework 級設定（monolog 等）は `app/config/eccube/packages/`**。entrypoint が起動時に
  本体の `app/config/eccube/packages/` へマージする（既定は消さない）。
  **切り替えたいものは `app/config/eccube/optional/<名前>/`** に置く。`packages/` は常に
  入るので、Redis のように「無い環境では 500 になる」設定を置くと初回から壊れる。
- 既定は本番モード。開発でデバッグするときだけ `.env` を `APP_ENV=dev` にする。
- **本番モードでキャッシュを消すときは `cache:clear` だけでは足りない。** Redis 上の
  Doctrine メタデータ（`cache:pool:clear --all`）と OPcache（php-fpm へ USR2）も
  消す。`opcache.validate_timestamps=Off` のためファイルを更新しても php-fpm は
  古いコンパイル結果を返し続ける。**OPcache は CLI では無効**なので `bin/console`
  からは正常に見え、ブラウザだけ壊れる。`bin/plugin.sh` の各コマンドは両方消す。
- **EC-CUBE 4.4 のコンパイル済みテンプレートは `var/runtime/<env>/twig` にあり、`cache:clear` は
  消さない。** 4.4 はキャッシュを `var/build`・`var/cache`・`var/runtime` の 3 か所に分けた。本番モードの
  Twig は更新を見ないので、**テンプレートを直してもプラグインを更新しても古い画面が出続ける**（例外も
  出ない）。`bin/plugin.sh`（`clear_twig_runtime`）と entrypoint が `cache:clear` の前に消す。
  テストも同じで、`bin/test.sh` は `var/runtime/test/twig` も消す。本体の `eccube:cache:build` も
  ここを消す。
- **本番モードでは「キャッシュが古い」こと自体はエラーにならない。** ファイルを足しても
  コンパイル済みコンテナには入らないので、**足したサービスやタグだけが例外も 500 も
  出さずに効かない**。実例: 承認対象を決めるタグ付きサービスを1つ足したのに古い並びが
  焼かれたままで、取引先の会員登録が承認制にならなかった。コードもタグも正しいので、
  ソースを読んでもテストを流しても見つからない。切り分けは
  `var/cache/prod/Container*/get<サービス>Service.php` を読んで、期待した定義が
  焼かれているかを見るのが速い。
  **`git pull` でプラグインを更新した直後がいちばん危ない**（ファイルだけ新しくなる）。
  - **キャッシュの組み立ては数分かかる。止めないこと。** 途中で止めると
    コンパイル済みコンテナが消えたまま残り、**全ページが 500 になる。**
    実際にそれでサイトを落とした。`warm_cache()` は始める前に一行出すので、
    黙っていても動いている。
  - **この種のコマンドの出力をパイプに通さない。** `docker compose exec ... | tail`
    のように読み手を挟むと、その読み手を先に止めたときコンテナの中の php が
    書き込みでブロックし、**終わったように見えて終わらない。** 固まったと
    誤解して強制終了 → キャッシュが壊れる、という道をたどる。ファイルへ
    落として、必要なときだけ読む。
  - `bin/plugin.sh reload` はキャッシュの組み立てに失敗したら**止まる**。
    黙って続けると「成功と表示されたのに古いコンテナが残る」ことになり、
    足したサービスやタグだけが効かない状態を自分で作る。warmup は重いので
    `memory_limit` は 1G で回す（`PLUGIN_CACHE_MEMORY_LIMIT` で変えられる）。
  - `bin/plugin.sh doctor` … コンパイル済みコンテナより新しいファイルがあれば挙げる
  - `bin/plugin.sh watch` … 見張って自動で reload。開発中は別のターミナルで放っておく
- **`docker compose` のプロジェクト名がずれると、直したつもりで直らない。**
  `compose.yaml` の `name:` と別名でスタックを起動していると、`bin/*.sh` は
  `name:` のほうへ行く。**止まっているスタックにも `exec` は通ってしまう**ので、
  reload も doctor も成功したように見えてブラウザは古いままになる。上の
  「効かないプラグイン」も、元をたどるとこれで reload が空振りしていた。
  `.env` に `COMPOSE_PROJECT_NAME=<稼働中の名前>` を書いて固定する。
  同じ `app/` を bind-mount した二重起動は `app/proxy/entity` を奪い合うので、
  使わないスタックは落としておく。
- **プラグインの install/enable/disable は前後でキャッシュ操作が要る。**
  `doctrine.yaml` の `auto_generate_proxy_classes` は `%kernel.debug%`（prod では
  false）なので、Doctrine のプロキシはウォーマーでしか作られない。EC-CUBE 本体の
  プラグインコマンドは内部で `cache:clear --no-warmup` までしかやらないため、
  **前**に `cache:pool:clear --all`、**後**に warmup 込みの `cache:clear` が必要。
  怠るとこうなる:
  - 前を怠る → `Property Eccube\Entity\Product::$BundleItems does not exist` で
    コマンドが異常終了する（`var/cache` を消しても直らない。実体は Redis 側）。
  - 後を怠る → トレイトで足した getter が**例外も出さずに空のコレクション**を返す。
    `findBy()` は件数を返すのに `$Product->getBundleItems()` は 0 件、という
    食い違いになり、プラグインの Processor が黙って何も記録しない。
  `bin/plugin.sh` の各コマンドは両方やる（前が `prepare_plugin_command`、後が
  `settle` = 後始末 → test/プール/OPcache 削除 → warmup 込みの `cache:clear`）。
  組み立てを次のリクエスト任せにすると、そこへ別のリクエストやコンソールコマンドが
  重なってコンパイル済みコンテナが書きかけのまま残り、全ページ 500 になる。
  **素の `bin/console eccube:plugin:enable` を直接叩かない。**
- **有効化はエンティティ拡張の列を戻さない。** 無効化で落ちた列は
  `eccube:plugin:enable` では復活しない。プロキシにはトレイトが入り、Doctrine の
  メタデータも列を知っているのに、テーブルにだけ無い、という食い違いになる。
  有効化は `[OK] Plugin Enabled.` と出すので成功に見え、**画面かテストが落ちるまで
  気づけない**（`Column not found: 1054 Unknown column 't0.company_account'`）。
  `bin/plugin.sh` の enable / install / add が `eccube:plugin:schema-update` を
  **キャッシュを組み立てる前に**打つ。順番が逆だと warmup が列を読みにいって落ち、
  古いコンパイル済みコンテナが残る（実際に踏んだ）。
  **失敗は握りつぶさない。** 4.4 の `schema-update` は**エンティティを1つも持たない
  プラグインでも 0 を返す**ので、非ゼロは接続不良・マイグレーションの SQL エラー・
  ロックといった本物の異常だけ。握ると列が無いまま「完了」と表示することになる。
- **プラグインをファイルだけ新しくしても DB は追いつかない。** `git -C app/Plugin/<Code> pull` で
  列を足した版にすると、本体の更新処理（スキーマ更新・`PluginManager::update()`・版の書き換え）を
  誰も通らず、そのエンティティを読む画面が「Column not found」で 500 になる。`bin/deploy.sh` は
  migration のあとに `bin/plugin.sh sync` を打つ。**版が変わったものは `eccube:plugin:update`**
  （スキーマ更新だけでは `update()` で既存の店の設定を引き継ぐプラグインが壊れる）、版は同じで
  `Entity/` だけ変わったものは schema-update。全部に打たないのは 1 個 7 秒かかるから
  （指紋は `var/plugin-sync/`）。
- **プラグインを入れ替えると、列のデータが別のプラグインへ移ることがある（4.4。止めてある）。**
  本体の `SchemaService::updateSchema` は Doctrine DBAL 4 の比較器を既定のまま使い、同じテーブルで
  「無効にしたプラグインの列が消える」と「有効にするプラグインの列が増える」が同時に起き、型が
  同じだと**名前の変更とみなして `CHANGE 古い列 新しい列`** を打つ。データはそのまま移る。
  実例: 取引先アカウント管理を無効にして営業担当者を有効にしたら、会員の「所属する取引先」の ID が
  「担当営業」の ID になった。**番号が担当者の ID と重なると外部キーも通り、有効化は成功と出る。**
  `app/config/eccube/packages/schema_rename_guard.php`（クラスは `lib/`）が `SchemaService` を
  差し替え、名前の変更の推測だけを切る。`app/Customize` に置かないのは、利用者のもので
  self-update が届けられないため。**4.2 / 4.3 では本体へそのまま渡す**（Doctrine が古く切る設定が無い）。
- **スキーマ更新が、無効なプラグインの列をデータごと消していた（4.4。止めてある）。**
  本体の schema-update（`bin/plugin.sh enable / install / add / update`、`deploy.sh` の `sync`、
  オーナーズストアの更新が通る）は、**有効なプラグインだけ**のメタデータと DB を比べる。「追加だけ」の
  saveMode が外すのはテーブルとシーケンスの削除だけで、**列・索引・外部キーの削除は残る。**
  インストール済みで無効のプラグインがあると、別のプラグインを有効化した瞬間にその列が DROP される。
  実例（2026-11-19、37 本インストール・全部無効のデモ本番）: `bin/plugin.sh enable` を 1 本打ち、
  他のプラグインの列 46 本を消した。エラーは出ず、消えた側を有効にした時点で Unknown column。
  同じ差し替え（`RenameSafeSchemaService`）が、saveMode では **dtb_plugin に載っているプラグイン
  （有効・無効を問わない）のエンティティが宣言する列**と、それに掛かる索引・外部キーを削除から外す。
  無効なものはメタデータに無いので、属性をリフレクションで読む。**どのプラグインも宣言していない列は
  今までどおり消える**: アンインストール中のプラグインの列（本体が先に dtb_plugin から外す）と、
  プラグインの新しい版が宣言から外した列（データも消える。残したいならその版で宣言を外さない）。
  エンティティが 1 つでも読めなければ、その回は列・索引・外部キーの削除を一切しない（安全側）。
- **管理画面（オーナーズストア → プラグイン一覧）から有効化・無効化したら、その直後に
  `bin/plugin.sh reload` を実行する。** 本体の `PluginController` は `cacheUtil->clearCache()`
  しか呼ばず、これは `kernel.terminate` で `cache:clear --no-warmup` を走らせるだけ。
  php-fpm は `opcache.validate_timestamps=0` なので、`opcache_reset()` の届き方と
  メンテナンス解除（`SystemService::disableMaintenanceEvent`）の順序次第で、
  古いエンティティクラスを掴んだままメタデータが作られることがある。結果:

      Unrecognized field: Plugin\CustomerGroup44\Entity\Group::$optionCompanyEntry

  実体（生成された `Group`）にはトレイトで項目があるのに、メタデータ側が知らない、
  という食い違い。プラグインを有効化した直後に、その画面ではなく**フロントの
  別ページ**が落ちるので原因にたどり着きにくい。`reload`（または `doctor`）で直る。
  なお、この2つは `kernel.terminate` の同じ優先度に登録されていて実行順が保証されない。
- **`.maintenance` が残ることがある。** 管理画面からプラグインを操作すると本体が
  `auto_maintenance` を自動で立てる。処理が途中で落ちると消されず、フロントだけ
  503「ただいまメンテナンス中です」になる。**管理画面は素通りできるので気づきにくい。**
  `bin/plugin.sh doctor` が自動で解除する（手動で入れたメンテナンスは残す）。
- **コンテナの中で `bin/console` を root のまま打たない。** `docker compose exec ec-cube php bin/console`
  は root で走り、その日のログ（`var/log/prod/site-<日付>.log`）やキャッシュを root の持ち物で作る。
  php-fpm（www-data）はそこへ書けないので、**エラーをログに書こうとしたリクエストだけが 500 になり、
  そのログも残らない。** 失敗したときだけ落ちるので、プラグインの不具合に見える（業務の自動化の
  「手で試す → 実際に送る」で実際に取り違えた）。`bin/console.sh` か `runuser -u www-data --` を使う。
  起動時は entrypoint が `var` を直し、動いている間にできたものは `bin/plugin.sh` の
  reload / doctor（`clean_leftovers`）が直す。
- **プラグインが勝手に無効へ落ちることがある。** 中断した操作の巻き添えで
  `dtb_plugin.enabled` が 0 になる。無効になっただけでは表向き何も起きないが、
  Doctrine のメタデータに拡張プロパティが残ったままだと
  「Property Plugin\...\Group::$optionEntry does not exist」で画面が落ちる。
  **落ちるのが管理画面の別ページ（レイアウト管理など）なので、原因にたどり着きにくい。**
  `bin/plugin.sh doctor` が「インストール済みだが無効」として挙げる。
- **システムエラーが出たら `bin/plugin.sh doctor`。** 残骸の掃除・無効プラグインの
  検出・エンティティ拡張の反映確認・キャッシュの組み立て直し・主要ページの疎通確認まで
  やる。ページが落ちているときだけ直近の CRITICAL を出す。

- **テストは `bin/test.sh` から実行する**。素の `vendor/bin/phpunit` だとコンテナの
  `APP_ENV=prod` が勝って prod カーネルが起動し、`WebTestCase` 系が
  「framework.test config is not set to true」で全部落ちる（`bin/test.sh` が
  `-e APP_ENV=test` を渡している）。テスト設定の DAMA が各テストを
  ロールバックするので DB は汚れない。メールは `packages/test/messenger.yaml` で
  テストだけ同期送信。詳細は `docs/testing.md`。
- **テスト設定は PHPUnit のバージョン別に 2 本ある。** EC-CUBE 4.2/4.3 は PHPUnit 9.6 +
  DAMA 6.x、4.4 は PHPUnit 11 + DAMA 8.x で、設定の書式が相互に非互換
  （DAMA の登録が `<listeners><listener>` ↔ `<extensions><bootstrap>`、カバレッジ対象が
  `<coverage>` ↔ `<source>`。DAMA 8.x には `PHPUnitListener` クラス自体が無い）。
  - `phpunit.xml` … PHPUnit 9 以前（4.2 / 4.3）
  - `phpunit.11.xml` … PHPUnit 10 以降（4.4〜）
  - **どちらを使うかは `bin/test.sh` がコンテナの `vendor/bin/phpunit` の実バージョンを
    見て選ぶ**（`.env` の `ECCUBE_VERSION` からは推測しない）。片方だけ直して
    もう片方を放置しない。
- **書式が合わないと PHPUnit は警告を出して読み飛ばすだけ**で、**DAMA のロールバックが
  黙って無効化される**。テストが本番と同じ DB へ書き込み続け、数千件を投入するテスト
  （プラグインの大規模カタログ検証など）でフロントが商品一覧のシステムエラーで落ちる。
  `bin/test.sh` は実行前に DAMA の登録方法を DOM で検証し、実行後に
  「The configuration file did not pass validation!」が出ていたらテストが緑でも
  失敗扱いにする。このエラーが出たら設定の書式を疑う。
- **テスト用のコンパイル済みコンテナは `cache:clear` では作り直されない。** テストは
  `APP_DEBUG=0` で走るので、`bin/console cache:clear` が作るデバッグ版
  （`Eccube_KernelTestDebugContainer`）とは別のファイル（`Eccube_KernelTestContainer`）を
  使う。**debug=false のコンテナはファイルの更新を一切見ない**ため、クラスを足しても
  反映されない。症状は「サービスがコンテナに登録されていない」形で出る。フォームの型なら
  `Too few arguments to function ...::__construct(), 0 passed in FormRegistry.php`。
  Symfony が DI を通さず `new` している合図で、コードではなくキャッシュが原因
  （`cache:clear` を何度打っても直らず、1時間溶かした）。`bin/test.sh` が
  `app/Plugin` と `app/Customize` の php/yaml/xml とコンテナの更新時刻を比べ、
  新しいものがあれば `var/cache/test` を消してから実行する。手で直すなら
  `docker compose exec ec-cube rm -rf var/cache/test`。
- **管理画面の Web テストは `dtb_member` を溜め、放置するとテストが固まる。**
  `Generator::createMember()` は faker の `word` から未使用の `login_id` を探すが、
  **ja_JP の単語は 182 語しか無い**。Web テストの Member はロールバックされないため、
  溜まった数が単語数に達すると `do/while` を永久に抜けられない。エラーも出ず
  PHP が CPU を回し続けるだけで、原因が分かりにくい（実際に 2 回踏んだ）。
  `bin/test.sh` が実行前に検出して `login_id` を `leaked-<id>` へ退避する。
  手で直すなら `UPDATE dtb_member SET login_id = CONCAT('leaked-', id) WHERE id > 2;`。
- **設定ファイルを編集したら `docker compose up -d --force-recreate ec-cube`。** 単一
  ファイルの bind mount（`./phpunit.xml:/var/www/html/phpunit.xml:ro`）はホスト側で
  書き換えても inode が変わってコンテナ側へ反映されないことがある。中途半端な内容を
  掴んだまま「Premature end of data」等で落ちる。`bin/test.sh` がホストとコンテナの
  バイト数を突き合わせて検出する。
- **コンテナは `no-new-privileges` + `cap_drop: ALL`**（`x-hardened`。#112）。要る capability だけ
  各サービスで `cap_add`。root で起動して自分のユーザーへ落ちる公式イメージが多いので
  SETUID / SETGID / CHOWN、80/443 を bind する nginx / caddy は NET_BIND_SERVICE。
  **サービスを足すときは `<<: *hardened` と `networks:` を必ず書く**（`default` ネットワークは
  無い）。`frontend` は公開層と nginx、`backend` はそれ以外。公開層から DB / Redis に届かない（#117）。
  Redis は `REDIS_PASSWORD`（`init.sh` が生成、空なら認証なし）。
- **Redis と Messenger は任意で、初回は無効。** スイッチは `.env` の `COMPOSE_PROFILES`
  一本（`redis` / `messenger`）。サービスの起動（profiles）と設定の投入
  （`app/config/eccube/optional/<名前>/` を entrypoint が `packages/` へ入れる／外す）が
  同じ値で決まる。**別々にすると「設定だけ入って Redis が居ない → 500」「worker だけ
  居なくてメールが DB に溜まる（エラーなし）」が黙って起きる。** `docker compose --profile`
  の CLI 指定は entrypoint に届かないので、必ず `.env` に書く。`doctor` が食い違いを見る。
  **redis を切り替えた瞬間、全員ログアウトになる。**
- **性能/スケール（Tier 1）**: php-fpm は `.env` の `PHP_FPM_*`、OPcache は entrypoint が
  `APP_ENV` で切替、Redis 共有キャッシュは `optional/redis/redis_cache.yaml`（任意）、DB は
  `docker/mariadb/conf.d/`、nginx は gzip/静的キャッシュ済み。詳細は `docs/scale.md`。
- **nginx の `real_ip_recursive` は off、PHP へ渡す `X-Forwarded-For` は `$remote_addr` に置き換える。** on だと
  信じる範囲が全アドレスなので左端（お客さんが書ける値）まで遡り、ヘッダーを変えるだけでログインの回数制限が一度も
  効かなかった（試験で確かめた）。`trusted_proxies.yaml` は `X-Forwarded-Host` / `-Port` を信じない（ALB・Cloudflare LB
  は素通しするので、パスワード再設定のリンクを別ドメインへ向けられる）。nginx に**直接**届けば今も詐称できるので、
  公開層・LB 以外から届かないことが前提（本番は 127.0.0.1、`compose.app.yaml` は `HTTP_BIND` 必須）。
- **静的ファイルのキャッシュは、名前の変わらないもの（CSS・JS・テーマの画像）を 5 分、商品画像（`save_image`）だけ 30 日。**
  nginx と caddy の両方で揃える。EC-CUBE 4.2 / 4.3 は URL に版を付けず、`customize.css` は管理画面の「CSS 管理」と
  deploy が同じ名前のまま書き換えるので、長くすると直した CSS がブラウザと CDN の中継点に残る（v1.0.17 までは 30 日で、
  トンネルの Cloudflare が元の指定どおり 30 日持っていた）。**Cloudflare で HTML をキャッシュする設定（Cache Everything）に
  しない**（カート・ログイン・CSRF トークン入りのページを配る）。
- **セッション Redis 共有（Tier 2）**: 専用 `redis-session` に保存し複数ホストで共有。
  `optional/redis/redis_session.yaml` が **`framework.session.handler_id`** を
  `Customize\Session\RawRedisSessionHandler` に上書きする（`SESSION_REDIS_URL`）。
  **サービスを定義するだけでは使われない。** 本体の framework.yaml が `native_file` を指すので、
  以前の「SameSite ラッパの内側を差し替える」やり方は 4.4 ではどこからも参照されず、
  **セッションはずっとファイルに書かれていた**（#117 の検証で判明。`debug:config framework session`
  の `handler_id` で確かめる）。
- **アップロード画像（Tier 2）**: `html/upload` は専用ボリューム `eccube_upload` に分離。
  複数ホストは NFS/EFS ドライバに差し替えて共有。`down -v`（reset/switch-version）で
  ローカルデータは消えるので事前バックアップ。詳細は `docs/scale.md`。
- **複数ホスト + LB（Tier 2）**: 各アプリホストは `.env` の `COMPOSE_FILE=compose.app.yaml`（db/redis を含まない
  app 層。外部の共有サービスを見る）。**店は 1 台で作ってから移す**（アプリホストは `html/user_data` が ro で install できない）。
  init 役 1 台だけ `ECCUBE_SKIP_DB_INIT=0`、ほかは既定 1。**`TRUSTED_PROXIES` は既定の `REMOTE_ADDR` のまま**
  （nginx が X-Forwarded-For でお客さんの IP に置き換えるので、LB のサブネットを書くと HTTPS と判定されない。2 台で確かめた）。
  `ECCUBE_AUTH_MAGIC` は全台同じ、イメージは日付タグで揃える。EC-CUBE を上げるときは init 役以外を止め、init 役 → 残り
  （アプリホストの `upgrade.sh` はスキーマに触らない）。手順は `docs/scale.md`「複数ホスト + ロードバランサ」、LB 例は
  `docker/nginx/lb.conf.example`（各ホストの `:8080`）。
- **どこまで強くするかは `bin/loadtest.sh` で測ってから決める**（k6、`docs/loadtest.md`）。到着数を固定して流す
  （VU 固定だと遅くなるほど送る数も減り、限界の手前で余裕があるように見える）。**注文は流さない**（本物の受注と
  メール）。手元以外へはホスト名を打たないと流さず、手元でもこのプロジェクトの nginx のポートでなければ止める
  （作るときに、別名で立てた別のスタックへ smoke を流した）。
  **DB のリードレプリカとページ（HTML）のキャッシュは入れていない。** 本体の `TransactionListener` が毎回
  `beginTransaction()` するので Doctrine の replica は一度も使われず、一覧・詳細は人ごとの CSRF トークン
  （`form_rest`）とヘッダーのカート・ログインを持つので、そのまま配るとほかの人のカートが見えて「カートに入れる」が落ちる
  （`docs/scale.md`「3. DB が詰まったら」）。手元の試験で先に詰まったのは PHP。

## ドキュメントの置き場所

**README は入口だけ。** 設計方針・ディレクトリ・必要環境・クイックスタートまでで、
以降は `docs/` に分けてある。**README に長文を足さないこと。**

| 文書 | 中身 |
|---|---|
| `AGENTS.md` | **お店を運用する人とその AI 向け**（配布物に入る）。この CLAUDE.md は環境そのものの保守用 |
| `docs/handbook.md` | 初心者向け。理由を書かず手順だけ。毎日の 3 コマンドと困ったときの 1 コマンド |
| `docs/install.md` | 利用者向けの導入手順（取得 → 起動 → 更新の受け取り） |
| `docs/customize.md` | 本体を汚さずに実装を足す場所、framework 級設定 |
| `docs/upgrade.md` | バージョン切替とバージョンアップ、切り戻し |
| `docs/deploy.md` | 本番デプロイ |
| `docs/distribute.md` | 配布と更新（配布イメージ、`bin/self-update.sh`） |
| `docs/backup.md` | バックアップ / 復元 |
| `docs/data-safety.md` | `down` と `down -v` の違い、消えるコマンド、復旧 |
| `docs/scale.md` | 大規模アクセス、セッション・画像の共有、LB、メールの非同期化 |
| `docs/loadtest.md` | 負荷試験（`bin/loadtest.sh` と `docker/k6/eccube.js`）。目標の決め方・読み方・詰まった場所ごとの打ち手 |
| `docs/monitoring.md` | 監視 |
| `docs/testing.md` | ユニットテスト |
| `docs/security-updates.md` | ミドルウェアの脆弱性と Docker の設定の毎日の点検（Trivy・設定の決まり・Dependabot） |
| `docs/ide.md` | PhpStorm の設定 |

## よく使う操作

```bash
bin/init.sh                    # 初回セットアップ
bin/deploy.sh                  # 自分のコードを反映。退避→メンテ ON→pull→migration→プラグインDB→proxy→
                               # キャッシュ→疎通→OFF。失敗したら ON のまま止まる（壊れた画面を出さない）
bin/self-update.sh             # この環境自体を新しいリリースへ（--check で確認だけ）
bin/upgrade.sh ~4.3.2          # バージョンアップ（データ保持・運用環境向け）
bin/upgrade.sh ~4.3.2 --prod   # 本番はこちら。付けないと開発構成のまま公開される
bin/switch-version.sh ~4.2.0   # バージョン切替（データ破棄・開発用）
bin/reset.sh                   # DB 初期化
bin/publish.sh                 # 本番構成で起動（起動するだけ。本体の入れ替えはしない）
bin/console.sh <cmd>           # bin/console をコンテナの中で実行（www-data 固定）
                               # migration は --namespace=CustomizeMigrations を自動で補う
bin/shell.sh                   # コンテナに入る（既定 ec-cube・www-data）
bin/shell.sh db                # 他のサービス。--root で root

bin/ide-sync.sh                # IDE 用に本体・vendor を .ide/ へ写す（--proxy / --clean）

bin/assets.sh build            # 独自 scss → html/user_data/assets/css/customize.css
bin/assets.sh watch            # 上記を監視ビルド（dev の node サービス）
bin/assets.sh core-build       # 本体テーマ丸ごとの純正ビルド（Gulp/Webpack・Git 管理外）

bin/test.sh                    # テスト（app/Customize/Tests）
bin/test.sh app/Plugin/Foo/Tests  # パス指定でプラグインのテストも同じ設定で走る

# プラグイン（dev で app/Plugin が rw のとき）
bin/plugin.sh add git@github.com:you/MyPlugin.git   # clone→install→enable
bin/plugin.sh list                                  # 導入状況（enabled/version）
bin/plugin.sh reload                                # PHP/config 変更後のキャッシュ一掃
bin/plugin.sh sync                                  # ファイルだけ新しいプラグインの DB を追いつかせる（deploy が呼ぶ）
bin/plugin.sh watch                                 # 変更を見張って自動で reload
bin/plugin.sh doctor                                # システムエラー時の点検と修復
docker compose exec ec-cube runuser -u www-data -- php bin/console eccube:plugin:generate <Name>
```

## 開発フロー（重要）

**この節は eccube-docker 本家（kurozumi/eccube-docker）の開発者向け。** 自分の店のリポジトリでは
`main` に直接 push してよい（`docs/handbook.md` の手順がそう）。

- **`main` へ直接コミット・直接プッシュしない。** 変更は必ず作業ブランチを切り、
  プルリクエストを作成する。
- **マージはオーナー（kurozumi）が行う。** 明示的に「マージして」と指示されない限り、
  自分で `gh pr merge` しない。
- リポジトリ初期化時の初回プッシュのみ、例外的に直接 `main` へ反映済み。
