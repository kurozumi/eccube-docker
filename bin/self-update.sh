#!/usr/bin/env bash
# この Docker 環境（bin/ や compose ファイル）を新しいリリースへ更新する。
#
#   bin/self-update.sh            最新リリースへ更新
#   bin/self-update.sh --check    確認だけ（何も書き換えない）
#   bin/self-update.sh v1.2.0     版を指定（戻すこともできる）
#   bin/self-update.sh --force    自分で変更した環境ファイルも上書きする
#
# **更新するのは「環境」であって「EC-CUBE 本体」ではない。**
#   環境（bin/ compose docker/ docs/）  … このスクリプト
#   EC-CUBE 本体（イメージの中身）      … bin/upgrade.sh
# 順番は self-update → upgrade。逆にすると、新しい本体を古いスクリプトで扱う
# ことになる（本体の作法が変わったときに、その差分を知らないスクリプトが動く）。
#
# 触るもの・触らないもの:
#   上書きする … .eccube-docker-paths に列挙してあるもの
#                 （bin/ docker/ docs/ compose*.yaml phpunit*.xml .env.example
#                   .gitignore LICENSE README.md CLAUDE.md VERSION
#                   app/config/eccube/{packages,optional}）
#                 **正はスクリプト内の配列ではなく、これから入れる版の一覧。**
#                 ただし**その中で配布元が変えたファイルだけ**。あなたが
#                 bin/ に置いた独自スクリプトなどは触らない。
#   触らない   … .env / app/ / html/user_data / frontend/ / var/ / backups/ / .ide/
#                 **あなたの成果物と設定には一切触れない。**
#
# 「自分で変更したかどうか」は、いま入っている版のリリース内容と突き合わせて
# 判定する（手元に控えを持たない）。判定できないときは黙って上書きせず止まる。
set -euo pipefail

# ── 走りながら自分自身を書き換えることになるので、複製へ移ってから動く ──
# bash はスクリプトを少しずつ読み進めるため、実行中のファイルを置き換えると
# **途中から別の中身を読み始める。** 構文エラーで死ぬならまだよく、運が悪いと
# 「別のコマンドを実行した」状態で終わる。
if [ "${SELF_UPDATE_REEXEC:-0}" != "1" ]; then
    _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    _copy="$(mktemp)"
    cat "${BASH_SOURCE[0]}" > "$_copy"
    export SELF_UPDATE_REEXEC=1 SELF_UPDATE_ROOT="$_root" SELF_UPDATE_COPY="$_copy"
    exec bash "$_copy" "$@"
fi

# 後始末は**複製だけ**を消す。`rm -f "$0"` と書かないこと。SELF_UPDATE_REEXEC=1 を
# 手で立てて実行されると、$0 が実体を指していて**このスクリプト自身が消える。**
cleanup() { [ -n "${SELF_UPDATE_COPY:-}" ] && rm -f "$SELF_UPDATE_COPY"; rm -rf "${work:-}"; }
trap cleanup EXIT
cd "${SELF_UPDATE_ROOT:?}"
work=""

# 配布元。fork して使っている場合はここが自分の repo ではなく**配布元**を指す
# 必要があるため、origin からは推測しない（推測すると、リリースを持たない
# 自分の fork を見に行って「更新なし」と言い続けることになる）。
DEFAULT_REPO="kurozumi/eccube-docker"

# 環境側のパス。**ここに無いものは絶対に触らない。**
#
# **これは控えで、正は取得した新版の .eccube-docker-paths。** この一覧は
# 置き換えられる側に書いてあるので、新しい版でパスを足しても初回の更新では
# 届かない（LICENSE を足したときに実際にそうなった）。新版が一覧を持っていれば
# そちらを使う（下の load_paths）。持っていない古い版へ戻すときだけこれを使う。
ENV_PATHS=(
    bin
    docker
    docs
    # framework 級設定と任意機能の設定。app/ の下だが**環境側**のもので、
    # entrypoint が参照する（optional/ が無いと redis / messenger を有効にできない）。
    # 店が logging.yaml などを直していれば、衝突として止まる。
    app/config/eccube/packages
    app/config/eccube/optional
    compose.yaml
    compose.override.yaml
    compose.prod.yaml
    compose.app.yaml
    compose.postgresql.yaml
    phpunit.xml
    phpunit.11.xml
    .env.example
    .eccube-docker-paths
    .gitignore
    LICENSE
    README.md
    CLAUDE.md
    VERSION
)

log() { echo "[self-update] $*"; }
die() { echo "[self-update] エラー: $*" >&2; exit 1; }

# bin/lib/image.sh と同じもの。**あちらを source しない**のは、更新の途中で
# lib ごと置き換わるため（読み込み済みなら動くが、依存を持たないほうが確実）。
env_get() { # env_get KEY … シェルの環境変数 > .env
    local key="$1" val
    # 間接展開で見る。printenv は export されていない変数を見落とす。
    val="${!key-}"
    if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
    [ -f .env ] || return 0
    # **`|| true` と `return 0` を外さないこと。** set -o pipefail のもとでは
    # キーが無いときの grep の失敗がパイプライン全体の失敗になり、
    # `x="$(env_get FOO)"` の 1 行でスクリプトが黙って終了する。
    grep -E "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*$//' || true
    return 0
}

# ── 引数 ──
check_only=0
force=0
want=""
for a in "$@"; do
    case "$a" in
        --check) check_only=1 ;;
        --force) force=1 ;;
        -h|--help)
            # 行数を決め打ちしない。ヘッダを足すたびに途中で切れる（実際に切れていた）
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        -*) die "不明なオプション: $a" ;;
        *) want="$a" ;;
    esac
done

command -v curl >/dev/null 2>&1 || die "curl が必要です。"
command -v tar  >/dev/null 2>&1 || die "tar が必要です。"

repo="$(env_get ECCUBE_DOCKER_REPO)"
repo="${repo:-$DEFAULT_REPO}"

[ -f VERSION ] || die "VERSION がありません。この環境はリリース版ではないようです（更新は git で行ってください）。"
cur="$(tr -d '[:space:]' < VERSION)"
[ -n "$cur" ] || die "VERSION が空です。"
cur_tag="v${cur}"

# GitHub API はトークンがあれば使う（レート制限と private 対策）
api=(curl -fsSL -H "Accept: application/vnd.github+json")
gh_token="$(env_get GITHUB_TOKEN)"
[ -n "$gh_token" ] && api+=(-H "Authorization: Bearer ${gh_token}")

if [ -n "$want" ]; then
    target="$want"
    case "$target" in v*) ;; *) target="v${target}" ;; esac
else
    log "最新リリースを問い合わせています（${repo}）..."
    target="$("${api[@]}" "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
    [ -n "$target" ] || die "最新リリースを取得できませんでした（${repo}）。ネットワークか ECCUBE_DOCKER_REPO を確認してください。"
fi

log "現在: ${cur_tag}   更新先: ${target}   配布元: ${repo}"

if [ "$target" = "$cur_tag" ] && [ "$force" = "0" ]; then
    log "すでに最新です。"
    exit 0
fi

# ── 2 つのリリースを取ってくる ──
work="$(mktemp -d)"

fetch_release() { # fetch_release <タグ> <展開先> → 展開されたディレクトリを出力
    local tag="$1" dest="$2" inner
    mkdir -p "$dest"
    if ! "${api[@]}" "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}" \
            | tar -xzf - -C "$dest" 2>/dev/null; then
        return 1
    fi
    # tarball は <repo>-<バージョン>/ という 1 階層に入っている
    inner="$(find "$dest" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "$inner" ] || return 1
    printf '%s' "$inner"
}

log "更新先 ${target} を取得します..."
new_tree="$(fetch_release "$target" "$work/new")" || die "リリース ${target} を取得できませんでした。タグ名を確認してください。"

log "いま入っている ${cur_tag} を取得します（あなたの変更を見分けるため）..."
base_tree="$(fetch_release "$cur_tag" "$work/base" || true)"

# **更新対象の一覧は、これから入れる版のものを正とする。**
# 実行中のスクリプトの一覧は置き換えられる側なので、新しい版で足したパスが
# 初回の更新で届かない。新版が一覧を持っていればそれに従う。
# **mapfile を使わないこと。** bash 4 以降の組み込みで、**macOS の bash は 3.2**。
# `mapfile: command not found` で set -e が働き、何も出さずに死ぬ（実際に踏んだ）。
paths_file="${new_tree}/.eccube-docker-paths"
if [ -f "$paths_file" ]; then
    declared=()
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:blank:]')"
        [ -n "$line" ] && declared+=("$line")
    done < "$paths_file"
    if [ "${#declared[@]}" -gt 0 ]; then
        ENV_PATHS=("${declared[@]}")
        log "更新対象は ${target} の一覧に従います（${#ENV_PATHS[@]} 件）"
    fi
fi

# ── 差分を出す ──
tree_files() { # tree_files <ルート>
    local r="$1" p
    for p in "${ENV_PATHS[@]}"; do
        if [ -d "$r/$p" ]; then
            ( cd "$r" && find "$p" -type f -print )
        elif [ -f "$r/$p" ]; then
            printf '%s\n' "$p"
        fi
    done | LC_ALL=C sort -u
}

# A と B で中身が違う相対パスを出す。
# **diff -rq の出力は読まない。** ロケールでメッセージが変わるため、
# 日本語環境では "Files ... differ" を当てにできない。
tree_changes() { # tree_changes <A> <B>
    local a="$1" b="$2" f
    { tree_files "$a"; tree_files "$b"; } | LC_ALL=C sort -u | while IFS= read -r f; do
        if [ -f "$a/$f" ] && [ -f "$b/$f" ]; then
            cmp -s "$a/$f" "$b/$f" || printf '%s\n' "$f"
        else
            printf '%s\n' "$f"
        fi
    done
}

# 手元に控えを持たないので、いま入っている版のリリースを基準にする。
# 取れなかったときは「更新版と手元の差」しか出せず、**あなたの変更と更新の
# 中身が混ざる。** そのことを下で明示して止める。
if [ -n "$base_tree" ]; then
    incoming="$(tree_changes "$base_tree" "$new_tree")"
    mine="$(tree_changes "$base_tree" ".")"
    # **comm 自体も LC_ALL=C で回す。** sort だけ C にしても足りない。
    # ロケールが違うと comm は入力を「ソートされていない」と見なし、
    # **警告も出さず終了コード 0 のまま空を返す。** そうなると衝突が
    # 1 件も出ず、あなたの変更を黙って上書きすることになる。
    conflicts="$(LC_ALL=C comm -12 <(printf '%s\n' "$incoming" | sed '/^$/d' | LC_ALL=C sort -u) \
                                   <(printf '%s\n' "$mine" | sed '/^$/d' | LC_ALL=C sort -u))"
else
    incoming="$(tree_changes "$new_tree" ".")"
    mine=""
    conflicts=""
fi
incoming="$(printf '%s\n' "$incoming" | sed '/^$/d')"
mine="$(printf '%s\n' "$mine" | sed '/^$/d')"
conflicts="$(printf '%s\n' "$conflicts" | sed '/^$/d')"

count() { [ -n "$1" ] && printf '%s\n' "$1" | wc -l | tr -d ' ' || printf '0'; }

echo
if [ -z "$incoming" ]; then
    log "環境ファイルに差分はありません。"
else
    log "更新で変わるファイル（$(count "$incoming") 件）:"
    printf '%s\n' "$incoming" | sed 's/^/    /'
fi

if [ -z "$base_tree" ]; then
    echo
    log "注意: ${cur_tag} のリリースを取得できませんでした。"
    log "      **あなたが環境ファイルを変更しているかどうか判定できません。**"
    log "      このまま進めると、変更していた場合それは失われます。"
    [ "$force" = "1" ] || die "確認できないので中止します。承知のうえなら --force を付けてください。"
fi

if [ -n "$mine" ]; then
    echo
    log "あなたが変更している環境ファイル（$(count "$mine") 件）:"
    printf '%s\n' "$mine" | sed 's/^/    /'
fi

if [ -n "$conflicts" ]; then
    echo
    log "**このうち次のファイルは、更新でも変わります。上書きすると失われます:**"
    printf '%s\n' "$conflicts" | sed 's/^/    /'
    if [ "$force" = "0" ]; then
        echo
        log "中止しました。何も書き換えていません。"
        log "  変更を残したいなら、先に退避するか、更新後に入れ直してください。"
        log "  破棄してよいなら: bin/self-update.sh ${target} --force"
        exit 1
    fi
    log "--force が指定されているので上書きします。"
fi

# ── .env に足りないキー ──
env_keys() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null | tr -d '=' | LC_ALL=C sort -u || true; }

new_keys=""
if [ -f .env ] && [ -f "$new_tree/.env.example" ]; then
    new_keys="$(LC_ALL=C comm -23 <(env_keys "$new_tree/.env.example") <(env_keys .env) | sed '/^$/d')"
    if [ -n "$new_keys" ]; then
        echo
        log "**あなたの .env に無いキーが .env.example に増えています:**"
        printf '%s\n' "$new_keys" | sed 's/^/    /'
        log "  .env は更新しません（あなたの設定なので）。"
        log "  **未設定でも compose の既定値で起動するため、エラーにはなりません。**"
        log "  必要なものは .env.example を見て自分で足してください。"
    fi
fi

if [ "$check_only" = "1" ]; then
    echo
    log "--check なので何も書き換えていません。"
    exit 0
fi

echo
# `read` は EOF（パイプ経由・非対話）で非 0 を返す。**`|| true` を外さないこと。**
# set -e のもとでは、そこで理由も出さずに終了してしまう。
ans=""
read -r -p "[self-update] ${cur_tag} → ${target} へ更新します。続行しますか? [y/N] " ans || true
[ "$ans" = "y" ] || { log "中止しました。何も書き換えていません。"; exit 1; }

# ── 適用 ──
#
# **ディレクトリごと入れ替えない。** bin/ を丸ごと差し替えると、更新では
# 変わらないファイルにあなたが入れた手が巻き添えで消える。上の「衝突」の
# 一覧が「失われるのはこれだけ」という意味にならなくなる。
# 触るのは「配布元で変わったファイル」だけにする。あなたが自分で足した
# ファイル（bin/ に置いた独自スクリプトなど）はどちらにも無いので残る。
applied=0
removed=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$new_tree/$f" ]; then
        mkdir -p "$(dirname "./$f")"
        cp -a "$new_tree/$f" "./$f"
        applied=$((applied + 1))
    elif [ -n "$base_tree" ] && [ -e "./$f" ]; then
        # 配布元から消えたファイル。**基準（${cur_tag}）が取れているときだけ消す。**
        # 取れていないときの incoming には、あなたが足したファイルも混ざっている。
        rm -f "./$f"
        # `$f（` と書くと bash が全角括弧まで変数名に取り込んで
        # 「f（: unbound variable」で落ちる（bin/ide-sync.sh にも同じ注意書きがある）。
        log "削除: ${f}（更新版には含まれません）"
        removed=$((removed + 1))
    fi
done <<< "$incoming"

# VERSION はタグを正とする（リリース側の書き忘れに引きずられないため）
printf '%s\n' "${target#v}" > VERSION

echo
log "完了。${cur_tag} → ${target}（更新 ${applied} 件 / 削除 ${removed} 件）"
echo
log "次にやること:"
log "  1) 設定ファイルが変わっているので、コンテナを作り直す:"
log "       docker compose up -d --force-recreate"
log "     （単一ファイルの bind mount は inode が変わると反映されないため）"
if [ -n "$new_keys" ]; then
    log "  2) .env に足りないキーを確認する（上に一覧を出しています）"
    log "  3) EC-CUBE 本体を上げるなら bin/upgrade.sh <制約>"
else
    log "  2) EC-CUBE 本体を上げるなら bin/upgrade.sh <制約>"
fi
log "  リリースの内容: https://github.com/${repo}/releases/tag/${target}"
