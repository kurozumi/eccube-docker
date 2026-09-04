#!/usr/bin/env bash
# IDE（PhpStorm 等）にコード補完を効かせるため、コンテナの中にしか無い EC-CUBE 本体と
# vendor をホストの .ide/ へ写す。
#
#   bin/ide-sync.sh            vendor と src/Eccube を同期（既存の写しは作り直す）
#   bin/ide-sync.sh --proxy    app/proxy/entity も出す（エンティティ拡張を書くとき）
#   bin/ide-sync.sh --clean    .ide/ を消す
#
# なぜ要るか:
#   本体は名前付きボリューム eccube_app に展開され、bind-mount しているのは app/ と
#   html/user_data だけ。つまり **ホストには vendor も src/Eccube も 1 ファイルも無い**。
#   IDE はそれらを見つけられないので、Eccube\Entity\Order も Symfony も Doctrine も
#   「未定義のクラス」になり、補完も定義ジャンプも効かない。
#
#   リモートインタプリタ（Docker Compose）を設定しても直らない。あれが読むのは PHP 本体の
#   バージョンと拡張だけで、composer の依存は解決しない。ホストに実体を置くしかない。
#
# .ide/ は .gitignore 済み。イメージの複製なので消しても作り直せる。バージョンを
# 切り替えたら（bin/switch-version.sh / bin/upgrade.sh）写しは古くなるので実行し直す。
#
# PhpStorm 側の設定は最後に表示する。
set -euo pipefail
cd "$(dirname "$0")/.."

dest=.ide
fail() { echo "[ide-sync] エラー: $*" >&2; exit 1; }

with_proxy=0
for arg in "$@"; do
    case "$arg" in
        --proxy) with_proxy=1 ;;
        --clean)
            rm -rf "$dest"
            echo "[ide-sync] $dest を削除しました。IDE の Include Path からも外してください。"
            exit 0
            ;;
        -h|--help|help)
            # 先頭のコメント塊だけを出す（shebang を飛ばし、最初の非コメント行で止める）。
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        # ${arg} と括る。bash は非 ASCII のバイトを変数名の一部と見なすことがあり、
        # $arg（... と書くと「arg（: unbound variable」で落ちる。
        *) fail "不明な引数: ${arg}（--proxy / --clean / --help）" ;;
    esac
done

# コンテナが動いているか。止まっているスタックには exec が通らない。
# **プロジェクト名のズレはここで名前ごと出す**（lib/stack.sh）。
source "$(dirname "$0")/lib/stack.sh"
stack_require_running ec-cube ide-sync || exit 1

docker compose exec -T ec-cube test -d /var/www/html/vendor >/dev/null 2>&1 \
    || fail "ec-cube コンテナから /var/www/html/vendor を読めません。
       本体の展開が終わっているか確認してください（bin/init.sh）。"

# 書きかけの写しを IDE に読ませないため、別名で展開してから入れ替える。
# 途中で失敗しても直前の写しがそのまま残る。
tmp="$dest.new"
rm -rf "$tmp"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

echo "[ide-sync] 本体と vendor を写しています（200MB 程度・1 分ほど）..."
# docker compose cp はファイル単位で往復するため 17,000 ファイルでは実用にならない。
# tar でまとめてストリームする。set -o pipefail が効いているので途中の失敗は拾える。
docker compose exec -T ec-cube tar cf - -C /var/www/html vendor src composer.json composer.lock \
    | tar xf - -C "$tmp"

if [ "$with_proxy" = 1 ]; then
    # app/proxy/entity は EntityExtension トレイトを適用し直したエンティティの生成物。
    # プラグインが足したプロパティ・getter はここにしか無いので、拡張を書くときは要る。
    echo "[ide-sync] app/proxy/entity を写しています..."
    mkdir -p "$tmp/proxy"
    docker compose exec -T ec-cube tar cf - -C /var/www/html/app/proxy entity \
        | tar xf - -C "$tmp/proxy"
fi

# 展開が途中で終わっていないか（tar は部分的に成功しうる）。
[ -f "$tmp/src/Eccube/Entity/Order.php" ] \
    || fail "写しが不完全です（src/Eccube/Entity/Order.php がありません）。もう一度実行してください。"
[ -f "$tmp/vendor/autoload.php" ] \
    || fail "写しが不完全です（vendor/autoload.php がありません）。もう一度実行してください。"

version="$(sed -nE "s/.*const VERSION = '([^']+)'.*/\1/p" "$tmp/src/Eccube/Common/Constant.php" | head -1)"
{
    echo "# bin/ide-sync.sh が作った複製。編集しても本体には反映されません。"
    echo "eccube_version=${version:-unknown}"
    echo "synced_at=$(date '+%Y-%m-%d %H:%M:%S')"
} > "$tmp/.synced"

rm -rf "$dest"
mv "$tmp" "$dest"
trap - EXIT

echo
echo "[ide-sync] 完了（EC-CUBE ${version:-unknown}）"
du -sh "$dest/vendor" "$dest/src" 2>/dev/null | sed 's/^/           /'
cat <<'EOS'

PhpStorm の設定（初回だけ）:

  Settings → Languages & Frameworks → PHP → Include Path タブ → + で追加

      .ide/vendor
      .ide/src
EOS
if [ "$with_proxy" = 1 ]; then
    cat <<'EOS'
      .ide/proxy/entity   ← プラグインが拡張したエンティティ

  proxy/entity は src/Eccube/Entity と FQCN が衝突する（同じクラスが 2 か所で
  定義されて見える）。エンティティ拡張を書いている間だけ入れるのが実際的。
EOS
fi
cat <<'EOS'

  **ソースルート（.iml の sourceFolder）には足さないこと。** Include Path なら
  解決だけに使われ、Find in Files や Refactor の対象からは外れる。

EOS
