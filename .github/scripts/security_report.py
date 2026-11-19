#!/usr/bin/env python3
"""毎日のセキュリティ点検の報告を作る（.github/workflows/security-scan.yml から呼ぶ）。

入力:
  argv[1] … 点検したイメージの一覧（1 行 1 つ）
  argv[2] … Trivy の JSON を置いたディレクトリ（<連番>.json と、同名の .ref にイメージ名）
  argv[3] … 受け入れ済みの一覧（.github/security-accept.json）
出力:
  report.md       … Issue の本文
  GITHUB_OUTPUT   … actionable=true|false

「要対応」にするもの:
  - 保守が終わった版（受け入れ済みを除く）
  - 60 日以内に保守が終わる版
  - 修正版のある CRITICAL / HIGH（Trivy の --ignore-unfixed）
判断（うちの構成で本当に効くか、上流の作り直し待ちか）はここではしない。人がやる（docs/security-updates.md）。
受け入れ済み（security-accept.json の accept）は、保守終了・まもなく終了のどちらでも「参考」に回す。
"""
import datetime as dt
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

TODAY = dt.date.today()
SOON_DAYS = 60
MAX_VULNS_PER_IMAGE = 15


def eol_target(image: str):
    """イメージ参照から (endoflife.date の製品名, 版の系列) を出す。分からなければ None。"""
    name, _, tag = image.rpartition(":")
    if not name:
        return None
    base = name.split("/")[-1]
    m = re.match(r"(\d+(?:\.\d+)?)", tag)
    if base == "ec-cube":  # 自分の配布イメージ。<系列>-php<版>
        pm = re.search(r"php(\d+\.\d+)", tag)
        return ("php", pm.group(1)) if pm else None
    if not m:
        return None
    ver = m.group(1)
    table = {
        "nginx": ("nginx", ver),
        "redis": ("redis", ver),
        "mariadb": ("mariadb", ver),
        "mysql": ("mysql", ver),
        "postgres": ("postgresql", ver.split(".")[0]),
        "node": ("nodejs", ver.split(".")[0]),
        "caddy": ("caddy", ver.split(".")[0]),
    }
    return table.get(base)


_cache = {}


def cycles(product: str):
    if product not in _cache:
        try:
            with urllib.request.urlopen(f"https://endoflife.date/api/{product}.json", timeout=30) as r:
                _cache[product] = json.load(r)
        except Exception as e:  # 取れないことは報告に書く（黙って「問題なし」にしない）
            _cache[product] = e
    return _cache[product]


def find_cycle(data, ver: str):
    """`7` のような大きい単位のタグは、その配下でいちばん新しい系列（7.4）に当てる。"""
    exact = [c for c in data if str(c.get("cycle")) == ver]
    if exact:
        return exact[0]
    under = [c for c in data if str(c.get("cycle")).startswith(ver + ".")]
    return under[0] if under else None  # endoflife.date は新しい順


def accepted(accept, product, ver):
    for a in accept:
        if a.get("product") == product and str(a.get("cycle")) == ver:
            review = a.get("review_by")
            if review and dt.date.fromisoformat(review) < TODAY:
                return None  # 見直し期限切れ。もう一度挙げる
            return a
    return None


def main():
    images = [l.strip() for l in Path(sys.argv[1]).read_text().splitlines() if l.strip()]
    trivy_dir = Path(sys.argv[2])
    accept = json.loads(Path(sys.argv[3]).read_text()).get("accept", [])

    actionable = False
    out = []
    out.append(f"毎日の点検（{TODAY.isoformat()}）の結果です。手順と判断の仕方は `docs/security-updates.md`。\n")

    # ── 保守期限 ──
    eol_rows, info_rows, seen = [], [], set()
    for img in images:
        t = eol_target(img)
        if not t or t in seen:
            continue
        seen.add(t)
        product, ver = t
        data = cycles(product)
        if isinstance(data, Exception):
            eol_rows.append(f"| {product} {ver} | `{img}` | **確認できず**（{data}） |")
            actionable = True
            continue
        c = find_cycle(data, ver)
        if not c:
            info_rows.append(f"| {product} {ver} | `{img}` | endoflife.date に系列が無い |")
            continue
        eol = c.get("eol")
        latest = c.get("latest", "")
        if eol is True or (isinstance(eol, str) and dt.date.fromisoformat(eol) <= TODAY):
            a = accepted(accept, product, ver)
            if a:
                info_rows.append(f"| {product} {ver} | `{img}` | 保守終了（{eol}）。受け入れ済み: {a.get('reason','')}（見直し {a.get('review_by','-')}） |")
            else:
                eol_rows.append(f"| {product} {ver} | `{img}` | **保守終了**（{eol}）。最新 {latest} |")
                actionable = True
        elif isinstance(eol, str) and (dt.date.fromisoformat(eol) - TODAY).days <= SOON_DAYS:
            a = accepted(accept, product, ver)
            if a:
                info_rows.append(f"| {product} {ver} | `{img}` | まもなく保守終了（{eol}）。受け入れ済み: {a.get('reason','')}（見直し {a.get('review_by','-')}） |")
            else:
                eol_rows.append(f"| {product} {ver} | `{img}` | **まもなく保守終了**（{eol}） |")
                actionable = True
    out.append("## 保守期限\n")
    if eol_rows:
        out += ["| 系列 | イメージ | 状態 |", "|---|---|---|", *eol_rows, ""]
    else:
        out.append("要対応なし。\n")
    if info_rows:
        out += ["<details><summary>参考</summary>\n", "| 系列 | イメージ | 状態 |", "|---|---|---|", *info_rows, "\n</details>\n"]

    # ── 脆弱性 ──
    out.append("## 修正版のある CRITICAL / HIGH\n")
    any_vuln = False
    failed = []
    for ref_file in sorted(trivy_dir.glob("*.ref")):
        img = ref_file.read_text().strip()
        jf = ref_file.with_suffix(".json")
        if not jf.exists() or jf.stat().st_size == 0:
            failed.append(img)
            continue
        try:
            doc = json.loads(jf.read_text())
        except json.JSONDecodeError:
            failed.append(img)
            continue
        vulns = {}
        for res in doc.get("Results") or []:
            for v in res.get("Vulnerabilities") or []:
                if v.get("Severity") not in ("CRITICAL", "HIGH") or not v.get("FixedVersion"):
                    continue
                key = (v["VulnerabilityID"], v.get("PkgName"))
                vulns[key] = v
        if not vulns:
            continue
        any_vuln = True
        actionable = True
        crit = sum(1 for v in vulns.values() if v["Severity"] == "CRITICAL")
        out.append(f"### `{img}` — CRITICAL {crit} / HIGH {len(vulns) - crit}\n")
        out += ["| CVE | 重さ | パッケージ | 入っている版 | 修正版 |", "|---|---|---|---|---|"]
        ordered = sorted(vulns.values(), key=lambda v: (v["Severity"] != "CRITICAL", v["VulnerabilityID"]))
        for v in ordered[:MAX_VULNS_PER_IMAGE]:
            out.append(f"| {v['VulnerabilityID']} | {v['Severity']} | {v.get('PkgName','')} | {v.get('InstalledVersion','')} | {v.get('FixedVersion','')} |")
        if len(ordered) > MAX_VULNS_PER_IMAGE:
            out.append(f"\n…ほか {len(ordered) - MAX_VULNS_PER_IMAGE} 件")
        out.append("")
    if not any_vuln:
        out.append("要対応なし。\n")
    if failed:
        actionable = True
        out.append("## 点検できなかったイメージ\n")
        out += [f"- `{i}`" for i in failed]
        out.append("\n**点検できなかったものは「問題なし」ではない。** pull できるか、Trivy が落ちていないかを確かめる。\n")

    out.append("\n<sub>配布イメージ（ec-cube）は OS のパッケージだけを見ている。`vendor` は EC-CUBE 本体の lock で、こちらでは触らない（CLAUDE.md）。</sub>")
    Path("report.md").write_text("\n".join(out) + "\n")
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a") as f:
            f.write(f"actionable={'true' if actionable else 'false'}\n")
    print("\n".join(out))
    print(f"\nactionable={actionable}")


if __name__ == "__main__":
    main()
