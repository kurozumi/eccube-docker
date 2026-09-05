# バックアップ / 復元

引っ越しと切り戻しに要るものを 1 か所に集める。**バージョンアップの前に必ず取る。**

何を消すと何が失われるかは [データを失わないために](data-safety.md) を見ること。

## 原則

**ディスクに残る状態は、git か backup のどちらかに必ず入る。**

管理画面は DB だけでなくファイルにも書く。それが git にも backup にも入っていないと、
「DB には行があるのにファイルが無い」形で引っ越し後に壊れる。

| 管理画面の操作 | 書く先 | git | backup |
|---|---|---|---|
| CSS 管理 / JS 管理 | `html/user_data/assets/{css,js}/customize.*` | 追跡（本番で書いた分は未コミット） | `admin-files.tar.gz` |
| メール設定で直した本文 | `app/template/<テーマ>/Mail/*.twig` | 追跡 | `admin-files.tar.gz` |
| ページ管理（新規ページ） | `app/template/user_data/*.twig` | 追跡 | `admin-files.tar.gz` |
| ブロック管理 | `app/template/<テーマ>/Block/*.twig` | 追跡 | `admin-files.tar.gz` |
| 差し替えた favicon・納品書のロゴ | `html/user_data/assets/{img,pdf}/` | **ignore** | `admin-files.tar.gz` |
| 買ったプラグインの実体 | `app/Plugin/<Code>/` | **ignore** | `admin-files.tar.gz`（`.git` 抜き。remote は `plugins.txt`） |
| テーマ切替・セキュリティ設定 | コンテナ内 `/var/www/html/.env` | — | `container.env`（**自動では戻さない**） |
| **`ECCUBE_AUTH_MAGIC`**・DB パスワード・トークン類 | ホストの `.env` | **ignore** | `host.env`（**自動では戻さない**。`restore.sh` が突き合わせて止める） |
| 画像アップロード | `html/upload`（専用ボリューム） | — | `upload.tar.gz` |
| それ以外 | DB | — | `db.sql.gz` |

**`ECCUBE_AUTH_MAGIC` が一番危ない。** 全パスワードのハッシュの鍵（`PasswordHasher` の salt）で、
新しいサーバーで違う値にすると、DB を戻しても**会員も管理者も誰もログインできない**。
エラーは出ず「パスワードが違う」と言われるだけ。`bin/restore.sh` は DB を戻す前にこれを
突き合わせ、違えば止める。

**本番で管理画面が書いたファイルは、そのサーバーの作業ツリーにしか無い。**
`bin/backup.sh` と `bin/plugin.sh doctor` が、コミットされていない分を挙げる。
git にも残すかは人が決める（残さなくても backup には入る）。

## 使い方

```bash
bin/backup.sh                        # ./backups/<日時>/ に 5 点セット（+ plugins.txt）
BACKUP_DIR=/mnt/nas bin/backup.sh    # 保存先変更
BACKUP_KEEP=14 bin/backup.sh         # 保持世代数（既定 7）

bin/restore.sh backups/20260721-040000   # 復元（確認プロンプトあり）
```

**引っ越しは「clone → `bin/init.sh` → `.env` の `ECCUBE_AUTH_MAGIC` を退避時の値に → `bin/restore.sh <退避先>`」。**
`restore.sh` が `app/Plugin` を戻したあと、プロキシとキャッシュを組み立て直す（DB は「有効」と
言っているので、ファイルが揃った時点で組み立てないと落ちる）。

`container.env` だけは自動で戻さない。`ECCUBE_ADMIN_ROUTE` のように compose が
環境変数で渡しているキーは、書き戻しても効かない（環境変数が勝つ）うえ、本体は
その状態を「上書きされている」と警告する。`restore.sh` が差分を出すので、必要な
ものはホストの `.env` に書く。**テーマ（`ECCUBE_TEMPLATE_CODE`）は `.env` に書くのが正。**
管理画面で選んだテーマはコンテナ内 `.env` に入り、`bin/upgrade.sh` でボリュームごと消える。

- DB は `mysqldump --single-transaction`（InnoDB 前提・**無停止で整合ダンプ**）
- cron 例（毎日 4:00）:
  ```
  0 4 * * * cd /path/to/eccube-docker && bin/backup.sh >> var/backup.log 2>&1
  ```
- バックアップ先はサーバー外（NAS / オブジェクトストレージ）へ同期すること。
  サーバー本体と同じディスクに置くだけでは障害時に共倒れになる。

---

[← README へ戻る](../README.md)
