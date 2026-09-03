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
