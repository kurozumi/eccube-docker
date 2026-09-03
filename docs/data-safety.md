# データを失わないために

**このリポジトリで最も取り返しがつかないのは、DB とアップロード画像を消すことです。**
どのコマンドが何を消すのか、消してしまったときに何が頼りになるのかをまとめます。

---

## `down` と `down -v` の違い

```bash
docker compose down        # コンテナを消すだけ。ボリュームは残る
docker compose down -v     # ★ボリュームごと消す
```

**`-v` を付けなければデータは消えません。** 誤って `down` しただけなら、
`docker compose up -d` で元どおり動きます。

| 中身 | 置き場所 | `down` | `down -v` | サーバーごと失ったら |
| --- | --- | --- | --- | --- |
| **受注・会員・商品**（DB） | ボリューム `db_data` | 残る | **消える** | **消える** |
| **アップロード画像** | ボリューム `eccube_upload` | 残る | **消える** | **消える**（NFS/EFS に出していれば残る） |
| セッション | ボリューム `redis_session_data` | 残る | 消える | 消える |
| EC-CUBE 本体・vendor | ボリューム `eccube_app` | 残る | 消える | 消える |
| **独自コード**<br>`app/Customize` `app/template` `app/Plugin` `app/DoctrineMigrations` | **ホストのファイル**（bind mount） | 消えない | **消えない** | Git にあれば残る |
| **独自 CSS/JS** `html/user_data` | **ホストのファイル**（bind mount） | 消えない | **消えない** | Git にあれば残る |

**自分で書いたものは Docker の操作では消えません。** bind mount なので、実体は
ホスト側の Git 管理下にあります。

**本体とプラグインの実体は消えても困りません。** `eccube_app` は再ビルドで戻り、
プラグインは `app/Plugin` に残ります。

**本当に危ないのは DB と画像の 2 つだけ**です。この 2 つはバックアップでしか戻せません。

---

## 消えるコマンド

| コマンド | `-v` | 何が起きるか |
| --- | --- | --- |
| `docker compose down` | なし | コンテナだけ消える。**データは無事** |
| `docker compose down -v` | **あり** | **DB・画像・セッションが消える** |
| `bin/reset.sh` | **あり** | DB を初期状態へ戻すのが目的。**本番で打ってはいけない** |
| `bin/switch-version.sh` | **あり** | 別バージョンをまっさらに立て直すのが目的。**名前から想像しにくいが本番では厳禁** |
| `bin/upgrade.sh` | なし | 本体ボリュームだけ個別に作り直す。**DB と画像は残す** |

**バージョンを上げたいだけなら `bin/upgrade.sh <制約> --prod`** です。
`switch-version.sh` はバージョンアップツールではありません。

### 本番では止まります

`bin/reset.sh` と `bin/switch-version.sh` は、**稼働中のスタックが本番構成
（`compose.prod.yaml`）なら対話の確認では通しません。**

```
[reset.sh] エラー: 稼働中のスタックは**本番構成**です（compose.prod.yaml）。
[reset.sh] 本番のデータを消そうとしています。

  本当に消すなら、プロジェクト名を渡して実行してください:
    CONFIRM_DESTROY=eccube-prod bin/reset.sh
```

判定は稼働中のコンテナに残る `com.docker.compose.project.config_files` ラベルを
見ています。**コンテナが停止していると判定できない**ので、そのときは
「判定できません」と出したうえで通常の確認に進みます。**止まっている本番で
打てば消えます。**

---

## 消してしまったら

**`down -v` を取り消す方法はありません。** ボリュームは即座に削除されます。
頼りはバックアップだけです。

```bash
bin/restore.sh backups/20260721-040000
```

だから、次の 2 つは**運用を始める前に**済ませてください。

### 1. 定期的に取る

```
0 4 * * * cd /path/to/eccube-docker && bin/backup.sh >> var/backup.log 2>&1
```

`bin/backup.sh` は DB を `mysqldump --single-transaction` で**無停止**で取り、
画像を tar.gz に固めます。世代は既定 7 で、`BACKUP_KEEP` で変えられます。

### 2. サーバーの外へ出す

**同じディスクに置くだけでは、サーバーを失ったときに一緒に消えます。**

```
0 4 * * * cd /path/to/eccube-docker && bin/backup.sh >> var/backup.log 2>&1
15 4 * * * rclone sync /path/to/eccube-docker/backups remote:eccube-backups
```

保存先を直接外部にすることもできます。

```bash
BACKUP_DIR=/mnt/nas bin/backup.sh
```

### 3. 戻せることを試しておく

**取れていることと戻せることは別です。** ステージングで一度
`bin/restore.sh` を通しておくと、いざというときに手が止まりません。

---

## よくある勘違い

**「`down` したらデータが消えた」** — `-v` が付いていたはずです。素の `down` では
消えません。まず `docker volume ls` で残っているか確かめてください。

**「`switch-version.sh` はバージョンアップだと思っていた」** — 違います。
まっさらに立て直すツールで、**受注も会員も消えます。** 上げるのは `upgrade.sh` です。

**「画像は DB に入っている」** — 入っていません。`eccube_upload` ボリュームです。
DB のダンプだけ取っていても画像は戻りません。`bin/backup.sh` は両方取ります。

**「Git にあるから大丈夫」** — 大丈夫なのはコードだけです。**受注・会員・画像は
Git にありません。**

---

[← README へ戻る](../README.md)
