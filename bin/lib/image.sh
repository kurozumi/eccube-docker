#!/usr/bin/env bash
# 配布イメージ（レジストリから pull）とローカル build を切り替えるための共通処理。
#
# **この環境は 2 通りの使われ方をする。**
#   1) 自分で build する（改造する人・開発）    … ECCUBE_IMAGE 未設定
#   2) 配布イメージを pull する（使うだけの人） … ECCUBE_IMAGE=ghcr.io/<owner>/<repo>/ec-cube:4.3-v1.0.0
#
# 起動系のスクリプトは `image_provision` を呼ぶだけでよく、どちらなのかを
# 自分で判断しなくてよい。
#
# **`up -d --build` を直接書かないこと。** 配布イメージを使っている利用者の
# 環境でそれを打つと、pull したイメージをローカル build で上書きしてしまう。
# 利用者の手元には EC-CUBE を取得できる composer 環境があるとは限らず、
# **成功しても中身が配布物と別物になる**（本体の取得タイミングが違うため）。
#
#   source "$(dirname "$0")/lib/image.sh"
#   image_provision "${dc[@]}" || ...

# 設定値を解決する。シェルの環境変数を優先し、無ければ .env を見る。
# （compose 自身は .env を読むが、スクリプト側は読まないため）
env_get() { # env_get KEY
    local key="$1" val
    # 間接展開で見る。**printenv は export されていない変数を見落とす**ので、
    # スクリプトの中で設定した値が拾えず、.env の古い値が勝ってしまう。
    val="${!key-}"
    if [ -n "$val" ]; then
        printf '%s' "$val"
        return 0
    fi
    [ -f .env ] || return 0
    # **`|| true` と `return 0` を外さないこと。** 呼び出し側は set -euo pipefail
    # なので、キーが無いときの grep の失敗が pipefail でパイプライン全体の失敗に
    # なり、`x="$(env_get FOO)"` の 1 行でスクリプトが黙って死ぬ。
    grep -E "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*$//' || true
    return 0
}

# compose が使うイメージ参照。compose.yaml の既定値と必ず揃えること。
image_ref() {
    local ref
    ref="$(env_get ECCUBE_IMAGE)"
    printf '%s' "${ref:-eccube-ec-cube:local}"
}

# ECCUBE_IMAGE がレジストリを指しているか（＝pull できるか）。
#
# docker と同じ判定にする: 最初の要素にドットかコロンがあるか localhost なら
# レジストリホスト、それ以外は Docker Hub 上の名前とみなされる。ローカル build の
# 既定値 `eccube-ec-cube:local` はスラッシュを含まないのでここで false になる。
image_uses_registry() {
    local ref first
    ref="$(image_ref)"
    case "$ref" in
        */*) first="${ref%%/*}" ;;
        *)   return 1 ;;
    esac
    case "$first" in
        *.*|*:*|localhost) return 0 ;;
    esac
    # Docker Hub（`owner/name`）も pull できる
    return 0
}

# 起動前にイメージを用意する。レジストリ参照なら pull、そうでなければ build。
#   image_provision <docker compose の呼び出し…>
# 失敗時は非 0 を返すだけで終了はしない（呼び出し側に .env を戻す処理があるため）。
image_provision() { # image_provision docker compose [-f ...]
    if image_uses_registry; then
        echo "[image] 配布イメージを取得します: $(image_ref)"
        "$@" pull ec-cube
    else
        echo "[image] イメージをビルドします（EC-CUBE の取得で数分かかります）..."
        "$@" build
    fi
}

# composer の制約から EC-CUBE の系列を取り出す。
#   ~4.3.0 → 4.3 / ^4.4.1 → 4.4 / 4.2.* → 4.2
image_series() { # image_series <制約>
    printf '%s' "$1" | sed -E 's/^[^0-9]*//; s/^([0-9]+\.[0-9]+).*/\1/'
}

# 系列ごとの phpredis。**両立しないので系列で決まる**（docker/php/Dockerfile 参照）。
#   4.2 / 4.3（Symfony Cache 6.4） … 6.0.x（6.1+ は hSet のシグネチャ変更で衝突）
#   4.4（Symfony Cache 7.4）       … 6.1 以上（symfony/cache が ext-redis <6.1 を conflict）
# **.github/workflows/build-image.yml の matrix と揃えること。**
image_phpredis_for_series() { # image_phpredis_for_series <系列>
    case "$1" in
        4.4) printf '6.3.0' ;;
        *)   printf '6.0.2' ;;
    esac
}

# 系列ごとの PHP。4.4 は土台が Symfony 7.4 なので 8.2 以上が要る。
# **.github/workflows/build-image.yml の matrix と揃えること。**
image_php_for_series() { # image_php_for_series <系列>
    case "$1" in
        4.4) printf '8.3' ;;
        *)   printf '8.2' ;;
    esac
}

# 参照のタグに入っている系列だけを差し替える。
#   ghcr.io/o/r/ec-cube:4.3-v1.0.0 + 4.4 → ghcr.io/o/r/ec-cube:4.4-v1.0.0
#   ghcr.io/o/r/ec-cube:4.3        + 4.4 → ghcr.io/o/r/ec-cube:4.4
# 系列で始まらないタグ（latest など）は**触らない**。何を指しているか分からない
# ものを機械的に書き換えると、別系列のイメージを黙って掴ませることになる。
image_retag_series() { # image_retag_series <参照> <系列>
    local ref="$1" series="$2" name tag
    case "$ref" in
        *:*) ;;
        *) printf '%s' "$ref"; return 0 ;;
    esac
    name="${ref%:*}"
    tag="${ref##*:}"
    case "$tag" in
        [0-9]*.[0-9]*) printf '%s:%s' "$name" "$(printf '%s' "$tag" | sed -E "s/^[0-9]+\.[0-9]+/${series}/")" ;;
        *) printf '%s' "$ref" ;;
    esac
}

# イメージに焼かれている EC-CUBE のバージョンを読む（取得できなければ空）。
#
# 配布イメージを使うとき、**.env の ECCUBE_VERSION は「何を build するか」でしか
# なく、実際に動くのはイメージに焼かれたバージョン**になる。両者は簡単にずれるので、
# 上げたあとに実物を確かめられるようにしておく。
image_baked_version() { # image_baked_version <参照>
    docker run --rm --entrypoint sh "$1" -c \
        'php -r "require \"vendor/autoload.php\"; echo Eccube\\Common\\Constant::VERSION;"' 2>/dev/null || true
}
