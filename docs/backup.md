# バックアップ / 復元

DB とアップロード画像を保全する。**バージョンアップの前に必ず取る。**


DB（受注・会員）とアップロード画像を 1 コマンドでバックアップできる。

```bash
bin/backup.sh                        # ./backups/<日時>/ に db.sql.gz + upload.tar.gz
BACKUP_DIR=/mnt/nas bin/backup.sh    # 保存先変更
BACKUP_KEEP=14 bin/backup.sh         # 保持世代数（既定 7）

bin/restore.sh backups/20260721-040000   # 復元（確認プロンプトあり）
```

- DB は `mysqldump --single-transaction`（InnoDB 前提・**無停止で整合ダンプ**）
- cron 例（毎日 4:00）:
  ```
  0 4 * * * cd /path/to/eccube-docker && bin/backup.sh >> var/backup.log 2>&1
  ```
- バックアップ先はサーバー外（NAS / オブジェクトストレージ）へ同期すること。
  サーバー本体と同じディスクに置くだけでは障害時に共倒れになる。

---

[← README へ戻る](../README.md)
