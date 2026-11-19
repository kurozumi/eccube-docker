## Docker の設定

compose は `docker compose config` で展開した結果（本番 3 通り・複数ホスト・開発）を見ている。

- `docker-sock` **本番（外部 DB） / db**: docker.sock をマウントしている（ホストの root と同じ）
- `port-bind` **本番（外部 DB） / db**: 0.0.0.0:3306 で外に開いている（127.0.0.1 に束縛する）
- `cap-add` **本番（外部 DB） / ec-cube**: 許可していない capability: SYS_ADMIN
- `secret-scope` **本番（外部 DB） / ec-cube**: DB_ROOT_PASSWORD が DB 以外に渡っている（#107）
- `privileged` **本番（外部 DB） / nginx**: privileged: true
- `image-tag` **本番（外部 DB） / nginx**: 本番で版の無いイメージ `nginx:latest`
- `backend-only` **本番（外部 DB） / redis**: 公開層（frontend）につながっている（#117）
- `nginx-server-tokens` **docker/nginx/default.conf**: server_tokens off; が無い（版が外に出る）

<details><summary>警告（開発の道具など）</summary>

- `cap-drop-all` 開発 / mailpit: cap_drop: ALL が無い（`<<: *hardened` を忘れている）（開発の道具）
- `no-new-privileges` 開発 / mailpit: security_opt: no-new-privileges が無い（開発の道具）
- `cap-drop-all` 開発 / node: cap_drop: ALL が無い（`<<: *hardened` を忘れている）（開発の道具）
- `no-new-privileges` 開発 / node: security_opt: no-new-privileges が無い（開発の道具）
- `cap-drop-all` 開発 / phpmyadmin: cap_drop: ALL が無い（`<<: *hardened` を忘れている）（開発の道具）
- `no-new-privileges` 開発 / phpmyadmin: security_opt: no-new-privileges が無い（開発の道具）
- Trivy の設定スキャン（Dockerfile）の結果が無い

</details>

