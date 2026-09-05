# 監視 / 可観測性

ログの見方と死活監視。


- **コンテナ死活**: `ec-cube`（php-fpm を FastCGI ping）を含む全サービスに healthcheck が
  あり、`docker compose ps` で healthy/unhealthy が分かる。nginx は ec-cube が healthy に
  なってから起動する。
- **db は認証まで確認する**。アプリと同じ経路（TCP + `DB_USER` + `DB_NAME`）で
  `SELECT 1` を流す。`mysqladmin ping` はサーバーが生きていれば**認証に失敗しても
  成功を返す**ので、DB ボリュームに焼かれたパスワードと `.env` が食い違っても healthy に
  なってしまう。`down -v` せずに `.env` の `DB_PASSWORD` を変えると起こり、
  「healthy なのにアプリだけ 500」という切り分けにくい状態になる。
  **パスワードを変えるときは DB 側も変える**:
  ```bash
  docker compose exec -T db sh -s <<'EOF'
  mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
  ALTER USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
  FLUSH PRIVILEGES;
  SQL
  EOF
  ```
  root のパスワードまで見失った場合は、`--skip-grant-tables` で一時起動して
  `ALTER USER` すれば**データを保ったまま**復旧できる（`down -v` は不要）。
- **php-fpm の飽和**（`max_children` 到達＝リクエスト滞留）は status page で確認:
  ```bash
  docker compose exec ec-cube sh -c \
    'SCRIPT_NAME=/fpm-status SCRIPT_FILENAME=/fpm-status REQUEST_METHOD=GET cgi-fcgi -bind -connect 127.0.0.1:9000'
  # active processes / idle processes / listen queue / max children reached を見る
  ```
  `max children reached` が増えていたら `PHP_FPM_MAX_CHILDREN` を上げる（メモリと相談）。
- **Docker ログ**は全サービス 10MB×5 世代で上限あり（ディスク食い潰し防止）。
- **外形監視**は UptimeRobot / Cloudflare Health Checks 等で `/` を監視する
  （`bin/healthcheck.sh` はローカル手動確認用）。

---

[← README へ戻る](../README.md)

## ログをサーバーの外へ出す

compose の `logging` は `json-file`（10MB × 5 世代）で、**そのサーバーにしか無い**。侵入や障害の
あとで見たいログが、いちばん見たいときに消えている（#119）。外へ出す方法は 2 段:

1. **Docker ごと出す**（推奨・compose を触らない）。`/etc/docker/daemon.json` で
   ```json
   { "log-driver": "journald" }
   ```
   にすると全コンテナのログが journald に入り、`journalctl CONTAINER_NAME=eccube-nginx-1` で
   引ける。journald から外へは `systemd-journal-remote`、または Vector / Promtail / Fluent Bit
   で Loki / CloudWatch / S3 へ。compose の `logging:` は driver を上書きするので、
   daemon.json を使うなら `compose.yaml` の `x-logging` を外す（`driver` を消せば daemon の既定）。
2. **アプリのログだけ出す**。EC-CUBE 自身のログは `eccube_app` ボリュームの `var/log/`
   （`site.log` / `front.log` / `admin.log` / `error.log`。管理画面の操作は `admin.log`）。
   `bin/backup.sh` には**入っていない**。残すなら cron で
   `docker compose cp ec-cube:/var/www/html/var/log ./var/log-$(date +%F)` を取って
   `BACKUP_SYNC` と同じ先へ送る。

最低限、**管理画面のログ（`admin.log`）と nginx のアクセスログ**が外にあれば、「誰がいつ何を
したか」は追える。
