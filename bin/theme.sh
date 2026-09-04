#!/usr/bin/env bash
# オリジナルテーマ（html/template/original）の静的物を本体から写し、本体を上げたときに
# 上流の変更を見えるようにする。
#
#   bin/theme.sh init          本体テーマの assets を html/template/original/assets へ写す
#   bin/theme.sh diff          自分の変更 / 上流の変更 / 衝突 を挙げる
#   bin/theme.sh status        写した時点の版と、いまの本体の版
#
# なぜ要るか:
#   twig は app/template/<code>/ に**直すファイルだけ**置けばよい（無ければ本体の
#   default にフォールバックする）。だが静的物は違う。asset() の base_path が
#   /html/template/<code> の 1 本だけで、フォールバックが無い。1 ファイル欠けると
#   その URL は 404 になる。**だから assets は丸ごと写すしかない。**
#
#   写した瞬間は同じでも、本体を上げると**古いほうが勝ち続ける**。例外は出ず、
#   直ったはずの崩れが戻る・新しい画像が出ない、という形でだけ現れる。
#   そこで写した時点の版と各ファイルの sha256 を .base に記録しておき、`diff` で
#   「自分が変えたもの」「上流が変えたもの」「両方（衝突）」を分けて出す。
#   bin/self-update.sh が環境ファイルでやっているのと同じ構造。
#
# 前提:
#   - テーマコードは original 固定。compose.yaml が html/template/original を bind
#     mount している（default にすると本体のテーマを空ディレクトリで覆い隠すため、
#     可変にしていない）
#   - .env に ECCUBE_TEMPLATE_CODE=original を書いて docker compose up -d する
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/guard.sh
. "$(dirname "$0")/lib/guard.sh"

code=original
dir="html/template/${code}"
base="${dir}/.base"

log() { echo "[theme] $*"; }
die() { echo "[theme] エラー: $*" >&2; exit 1; }

# 本体はボリュームの中にしか無い。ec-cube のイメージで `docker compose run` すると
# イメージが無いときにフルビルドが始まるので、alpine でボリュームを読む
# （bin/backup.sh と同じ理由）。
proj="$(guard_project_name)"
[ -n "$proj" ] || die "compose のプロジェクト名を取得できません"
vol() { docker run --rm -v "${proj}_eccube_app:/app:ro" alpine:3 "$@"; }

core_version() {
    vol sed -nE "s/.*const VERSION = '([^']+)'.*/\1/p" /app/src/Eccube/Common/Constant.php 2>/dev/null | head -1
}

# 本体テーマの assets を一時ディレクトリへ取り出す（出力: そのパス）
fetch_core_assets() {
    local tmp
    tmp="$(mktemp -d)"
    vol tar -C /app/html/template/default -cf - assets | tar -xf - -C "$tmp"
    [ -d "$tmp/assets" ] || die "本体テーマの assets を取り出せませんでした（ボリュームが無い？ docker compose up -d）"
    printf '%s' "$tmp"
}

# sha256 は環境で名前が違う（Linux: sha256sum / macOS: shasum -a 256）。
# **シェル関数にしないこと。** xargs はシェル関数を呼べず、`xargs: sha: not found`
# が 2>/dev/null に隠れて pipefail で黙って死ぬ（実際にそうなった。.base に
# version 行しか残らず、init が「完了」を出さずに終わった）。
if command -v sha256sum >/dev/null 2>&1; then sha_cmd="sha256sum"; else sha_cmd="shasum -a 256"; fi

# <ルート>/assets 以下の「<sha>  <相対パス>」一覧（相対パスは assets/ から）
manifest() { # manifest <ルート>
    # shellcheck disable=SC2086  # sha_cmd は単語分割させる
    ( cd "$1" && find assets -type f -print0 | LC_ALL=C sort -z | xargs -0 $sha_cmd ) \
        | sed -E 's/^([0-9a-f]+) [ *]?/\1  /'
}

# 2 つの manifest で違う相対パス（片方にしか無いものも含む）
changed() { # changed <manifestA> <manifestB>
    LC_ALL=C comm -3 <(LC_ALL=C sort "$1") <(LC_ALL=C sort "$2") \
        | sed -E 's/^\t//; s/^[0-9a-f]+  //' | LC_ALL=C sort -u
}

cmd="${1:-help}"
case "$cmd" in
  init)
    if [ -f "$base" ] && [ "${2:-}" != "--force" ]; then
        die "すでに写してあります（$(head -1 "$base")）。写し直すなら bin/theme.sh init --force
       （自分で直した分は消えます。先に bin/theme.sh diff で確かめてください）"
    fi
    ver="$(core_version)"
    [ -n "$ver" ] || die "本体のバージョンを読めませんでした（ボリュームが無い？ docker compose up -d）"
    log "本体（EC-CUBE ${ver}）のテーマ assets を ${dir}/assets へ写します..."
    src="$(fetch_core_assets)"
    rm -rf "${dir}/assets"
    mkdir -p "$dir"
    cp -a "$src/assets" "${dir}/assets"
    rm -rf "$src"
    {
        echo "version=${ver}"
        manifest "$dir"
    } > "$base"
    n="$(( $(wc -l < "$base") - 1 ))"
    log "完了。${n} ファイル。写した版を ${base} に記録しました。"
    echo
    log "次にやること:"
    log "  1) .env に ECCUBE_TEMPLATE_CODE=${code} を書く"
    log "  2) docker compose up -d   （nginx にも mount が要るので作り直される）"
    log "  3) git add ${dir} && git commit   （6MB ほど。静的物なので追跡する）"
    log "  twig を直すときは app/template/${code}/ に**直すファイルだけ**置く。丸ごと写さない。"
    ;;

  diff)
    [ -f "$base" ] || die "まだ写していません。bin/theme.sh init"
    base_ver="$(head -1 "$base" | cut -d= -f2-)"
    cur_ver="$(core_version)"
    log "写した版: EC-CUBE ${base_ver}   いまの本体: EC-CUBE ${cur_ver:-?}"

    src="$(fetch_core_assets)"
    trap 'rm -rf "$src"' EXIT
    b="$(mktemp)"; o="$(mktemp)"; u="$(mktemp)"
    tail -n +2 "$base" > "$b"
    manifest "$dir" > "$o"
    manifest "$src" > "$u"

    mine="$(changed "$b" "$o")"
    theirs="$(changed "$b" "$u")"
    both="$(LC_ALL=C comm -12 <(printf '%s\n' "$mine" | sed '/^$/d') <(printf '%s\n' "$theirs" | sed '/^$/d'))"
    rm -f "$b" "$o" "$u"

    echo
    if [ -z "$mine" ] && [ -z "$theirs" ]; then
        log "差分なし。写したときのままで、本体も変わっていません。"
        exit 0
    fi
    if [ -n "$mine" ]; then
        log "あなたが変えたファイル（$(printf '%s\n' "$mine" | wc -l | tr -d ' ') 件）:"
        printf '%s\n' "$mine" | sed 's/^/    /'
    fi
    if [ -n "$theirs" ]; then
        echo
        log "本体側で変わったファイル（$(printf '%s\n' "$theirs" | wc -l | tr -d ' ') 件）。**いまはあなたの写しが勝っている**:"
        printf '%s\n' "$theirs" | sed 's/^/    /'
        log "  本体のものを取り込むなら（1 ファイルずつ、内容を見てから）:"
        log "    cp ${src}/<相対パス> ${dir}/<相対パス>"
    fi
    if [ -n "$both" ]; then
        echo
        log "**両方が変えたファイル（衝突）**。手で合わせる必要があります:"
        printf '%s\n' "$both" | sed 's/^/    /'
        log "  比べる: diff ${src}/<相対パス> ${dir}/<相対パス>"
    fi
    if [ -n "$theirs" ]; then
        echo
        log "取り込みが終わったら、写した版を更新する: bin/theme.sh init --force"
        log "（あなたの変更を先に退避すること。init --force は assets を本体で置き換える）"
        # 一時ディレクトリを見せたので、この実行では消さずに残す
        trap - EXIT
        log "本体の assets は ${src} に残してあります（不要なら rm -rf）。"
    fi
    ;;

  status)
    if [ -f "$base" ]; then
        log "写した版: $(head -1 "$base")  ファイル数: $(( $(wc -l < "$base") - 1 ))"
    else
        log "まだ写していません（bin/theme.sh init）"
    fi
    log "いまの本体: EC-CUBE $(core_version || echo '?')"
    log ".env の ECCUBE_TEMPLATE_CODE: $(grep -E '^ECCUBE_TEMPLATE_CODE=' .env 2>/dev/null | cut -d= -f2- || echo '未設定（default）')"
    ;;

  *)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
