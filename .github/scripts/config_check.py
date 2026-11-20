#!/usr/bin/env python3
"""Docker の設定の安全性を点検する（security-scan.yml の毎日の点検と、設定を変える PR で動く）。

compose はファイルを読むのではなく `docker compose config` で**展開した結果**を見る。
上書き（compose.prod.yaml など）や YAML のアンカー（x-hardened）を経たあとの、実際に効く値で判定するため。

使い方:
  config_check.py <リポジトリの根> <受け入れ一覧.json> [Trivy の config 結果.json]
出力:
  config-report.md … 報告（security-scan の Issue に入る）
  終了コード       … 違反があれば 1（PR のチェックを落とす）

決まりの由来は CLAUDE.md（#107 / #110 / #112 / #117）。決まりを変えるときは CLAUDE.md も直す。
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
ACCEPT = json.loads(Path(sys.argv[2]).read_text()).get("config", [])
TRIVY_JSON = Path(sys.argv[3]) if len(sys.argv) > 3 else None

# 本番に効く組み合わせと、開発の組み合わせ。prod=True のものは厳しく見る
COMBOS = [
    ("本番（MariaDB）", ["compose.yaml", "compose.prod.yaml"], True),
    ("本番（PostgreSQL）", ["compose.yaml", "compose.postgresql.yaml", "compose.prod.yaml"], True),
    ("本番（外部 DB）", ["compose.yaml", "compose.externaldb.yaml", "compose.prod.yaml"], True),
    ("複数ホストのアプリ層", ["compose.app.yaml"], True),
    ("開発", ["compose.yaml", "compose.override.yaml"], False),
]

# 要る capability だけ（CLAUDE.md「コンテナは no-new-privileges + cap_drop: ALL」）。
# 足すなら理由をここに書く: 公式イメージは root で起動して自分のユーザーへ落ちる（CHOWN / SETUID / SETGID /
# DAC_OVERRIDE / FOWNER）、80/443 を bind（NET_BIND_SERVICE）、php-fpm が子を止める（KILL）、MariaDB の io（SYS_NICE）
ALLOWED_CAPS = {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID", "KILL", "NET_BIND_SERVICE", "SYS_NICE"}

# 外へ開けてよいポート（それ以外は 127.0.0.1 に束縛）
ALLOWED_PUBLIC = {
    ("本番（MariaDB）", "caddy"), ("本番（PostgreSQL）", "caddy"), ("本番（外部 DB）", "caddy"),
    # LB からしか届かせない前提（compose.app.yaml のコメント・docs/scale.md）
    ("複数ホストのアプリ層", "nginx"),
}

# 開発でだけ動く道具。固め（x-hardened）が無くても警告にとどめる（127.0.0.1 にしか開かないことは見る）
DEV_ONLY = {"mailpit", "node", "phpmyadmin"}

# 公開層（frontend ネットワーク）に置いてはいけないもの（#117）
BACKEND_ONLY = {"db", "redis", "redis-session", "ec-cube", "worker"}


def accepted(rule: str, target: str):
    for a in ACCEPT:
        if a.get("rule") == rule and a.get("target") == target:
            return a
    return None


violations, warnings, notes = [], [], []


def bad(rule, target, msg):
    a = accepted(rule, target)
    if a:
        notes.append(f"- `{rule}` {target}: {msg}（受け入れ済み: {a.get('reason','')}）")
    else:
        violations.append(f"- `{rule}` **{target}**: {msg}")


def env_file() -> str:
    """.env.example を元に、必須の秘密だけ仮の値を入れ、全プロファイルを有効にした .env を作る。"""
    src = (ROOT / ".env.example").read_text()
    lines = [l for l in src.splitlines() if not re.match(r"^#?\s*(DB_PASSWORD|DB_ROOT_PASSWORD|ECCUBE_AUTH_MAGIC|COMPOSE_PROFILES|COMPOSE_FILE|HTTP_BIND)=", l)]
    lines += [
        "DB_PASSWORD=dummy", "DB_ROOT_PASSWORD=dummy", "ECCUBE_AUTH_MAGIC=dummy",
        "COMPOSE_PROFILES=redis,messenger,caddy,tunnel",
        # 複数ホストのアプリ層は nginx を束縛する IP が必須（compose.app.yaml。使うのはこのファイルだけ）
        "HTTP_BIND=10.0.0.11",
    ]
    f = tempfile.NamedTemporaryFile("w", suffix=".env", delete=False)
    f.write("\n".join(lines) + "\n")
    f.close()
    return f.name


def check_combo(name, files, prod, envf):
    args = ["docker", "compose", "--project-directory", str(ROOT), "--env-file", envf]
    for f in files:
        args += ["-f", str(ROOT / f)]
    args += ["config", "--format", "json"]
    r = subprocess.run(args, capture_output=True, text=True, env={**os.environ, "COMPOSE_FILE": ""})
    if r.returncode != 0:
        bad("compose-resolve", name, f"`docker compose config` が通らない: {r.stderr.strip()[:300]}")
        return
    cfg = json.loads(r.stdout)
    for svc, s in cfg.get("services", {}).items():
        t = f"{name} / {svc}"
        dev_tool = (not prod) and svc in DEV_ONLY
        report = (lambda rule, msg: warnings.append(f"- `{rule}` {t}: {msg}（開発の道具）")) if dev_tool else (lambda rule, msg: bad(rule, t, msg))

        if "ALL" not in (s.get("cap_drop") or []):
            report("cap-drop-all", "cap_drop: ALL が無い（`<<: *hardened` を忘れている）")
        if not any(o.replace(" ", "") in ("no-new-privileges:true", "no-new-privileges") for o in (s.get("security_opt") or [])):
            report("no-new-privileges", "security_opt: no-new-privileges が無い")
        extra = set(s.get("cap_add") or []) - ALLOWED_CAPS
        if extra:
            bad("cap-add", t, f"許可していない capability: {', '.join(sorted(extra))}")
        if s.get("privileged"):
            bad("privileged", t, "privileged: true")
        for k in ("network_mode", "pid", "ipc", "userns_mode"):
            if str(s.get(k, "")).startswith("host"):
                bad("host-namespace", t, f"{k}: host")
        for v in s.get("volumes") or []:
            if "docker.sock" in str(v.get("source", "")):
                bad("docker-sock", t, "docker.sock をマウントしている（ホストの root と同じ）")
        nets = set((s.get("networks") or {}).keys())
        if not nets or "default" in nets:
            report("networks", "networks: が無い（default ネットワークは無い前提。#117）")
        if svc in BACKEND_ONLY and "frontend" in nets:
            bad("backend-only", t, "公開層（frontend）につながっている（#117）")
        for p in s.get("ports") or []:
            hip = p.get("host_ip") or "0.0.0.0"
            if hip not in ("127.0.0.1", "::1") and (name, svc) not in ALLOWED_PUBLIC:
                bad("port-bind", t, f"{hip}:{p.get('published')} で外に開いている（127.0.0.1 に束縛する）")
        img = str(s.get("image", ""))
        if prod and (img.endswith(":latest") or (":" not in img.split("/")[-1] and "@" not in img and svc not in ("ec-cube", "worker"))):
            bad("image-tag", t, f"本番で版の無いイメージ `{img}`")
        env = s.get("environment") or {}
        keys = set(env.keys() if isinstance(env, dict) else [e.split("=", 1)[0] for e in env])
        for k in keys:
            if "ROOT_PASSWORD" in k and svc != "db":
                bad("secret-scope", t, f"{k} が DB 以外に渡っている（#107）")
            if k == "TUNNEL_TOKEN" and svc != "cloudflared":
                bad("secret-scope", t, "TUNNEL_TOKEN が cloudflared 以外に渡っている（#107）")
            if k.startswith("BACKUP_"):
                bad("secret-scope", t, f"{k} がコンテナに渡っている（バックアップはホストで動く。#107）")
        if "frontend" in nets and svc not in ("cloudflared",):
            secret = [k for k in keys if re.search(r"PASS|SECRET|TOKEN|KEY|MAGIC", k)]
            if secret:
                bad("secret-scope", t, f"公開層に秘密が渡っている: {', '.join(sorted(secret))}")


def check_files():
    # コメントに書いてあるだけの `${X:?` で通らないよう、コメントを除いてから探す
    compose = "\n".join(re.sub(r"(^|\s)#.*$", "", l) for l in (ROOT / "compose.yaml").read_text().splitlines())
    for k in ("DB_PASSWORD", "DB_ROOT_PASSWORD", "ECCUBE_AUTH_MAGIC"):
        if not re.search(r"\$\{" + k + r":\?", compose):
            bad("required-secret", "compose.yaml", f"{k} が `:?` で必須になっていない（既定値で黙って立ち上がる。#110）")

    ng = (ROOT / "docker/nginx/default.conf").read_text()
    ng_active = "\n".join(l for l in ng.splitlines() if not l.strip().startswith("#"))
    if not re.search(r"^\s*server_tokens\s+off;", ng_active, re.M):
        bad("nginx-server-tokens", "docker/nginx/default.conf", "server_tokens off; が無い（版が外に出る）")
    if not re.search(r"location\s+~\s+/\\\.\s*\{[^}]*deny\s+all", ng_active):
        bad("nginx-dotfiles", "docker/nginx/default.conf", "ドットファイル（.env / .git）を deny していない")
    for h in ("X-Content-Type-Options", "X-Frame-Options", "Referrer-Policy"):
        if h not in ng_active:
            bad("nginx-headers", "docker/nginx/default.conf", f"{h} を付けていない")

    cf = ROOT / "docker/caddy/Caddyfile"
    if cf.exists():
        c = "\n".join(l for l in cf.read_text().splitlines() if not l.strip().startswith("#"))
        if not re.search(r"-Server\b", c):
            bad("caddy-server-header", "docker/caddy/Caddyfile", "Server ヘッダを消していない（`header -Server`）")
        for h in ("X-Content-Type-Options", "X-Frame-Options", "Referrer-Policy"):
            if h not in c:
                bad("caddy-headers", "docker/caddy/Caddyfile", f"{h} を付けていない（nginx と揃える）")
        if not re.search(r"respond\s+@denied\s+403", c):
            bad("caddy-denied", "docker/caddy/Caddyfile", "内部ディレクトリ（/vendor/* など）を 403 にしていない")
        # ドットファイルは別に見る。`/\.` を含む path_regexp の matcher が、403 で返されていること
        dot = [m for m in re.findall(r"@(\S+)[ \t]+path_regexp[ \t]+(?:\S+[ \t]+)?(\S+)[ \t]*$", c, re.M) if "/\\." in m[1]]
        if not any(re.search(r"respond\s+@" + re.escape(name) + r"\s+403", c) for name, _ in dot):
            bad("caddy-dotfiles", "docker/caddy/Caddyfile", "ドットファイル（どの階層でも）を 403 にしていない（`path_regexp /\\.` + `respond 403`）")


def check_trivy():
    if not TRIVY_JSON:
        warnings.append("- Trivy の設定スキャン（Dockerfile）を渡されていない（手元の実行）")
        return
    # 渡されたのに無い・空・壊れている = Trivy が落ちた。**「違反なし」にしない**
    raw = TRIVY_JSON.read_text().strip() if TRIVY_JSON.exists() else ""
    try:
        doc = json.loads(raw) if raw else None
    except json.JSONDecodeError:
        doc = None
    if not isinstance(doc, dict):
        bad("trivy-config", str(TRIVY_JSON), "Trivy の設定スキャンの結果が無い・空・壊れている（スキャンが落ちた）")
        return
    for res in doc.get("Results") or []:
        for m in res.get("Misconfigurations") or []:
            if m.get("Severity") in ("CRITICAL", "HIGH"):
                # Trivy は docker/ を根に走らせるので、Target は php/Dockerfile の形で来る
                bad(f"trivy:{m['ID']}", "docker/" + res["Target"], f"{m.get('Title','')}（{m['Severity']}）")


def main():
    envf = env_file()
    try:
        for name, files, prod in COMBOS:
            if all((ROOT / f).exists() for f in files):
                check_combo(name, files, prod, envf)
    finally:
        os.unlink(envf)
    check_files()
    check_trivy()

    out = ["## Docker の設定\n"]
    out.append("compose は `docker compose config` で展開した結果（本番 3 通り・複数ホスト・開発）を見ている。\n")
    out += (violations or ["要対応なし。"]) + [""]
    if warnings:
        out += ["<details><summary>警告（開発の道具など）</summary>\n", *warnings, "\n</details>\n"]
    if notes:
        out += ["<details><summary>受け入れ済み</summary>\n", *notes, "\n</details>\n"]
    Path("config-report.md").write_text("\n".join(out) + "\n")
    print("\n".join(out))
    sys.exit(1 if violations else 0)


if __name__ == "__main__":
    main()
