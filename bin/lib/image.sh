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
    printf '%s' "${ref:-eccube-ec-cube}"
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

# 系列ごとの**既定の** PHP（`-php` 無しの短いタグが指すもの）。4.4 は土台が Symfony 7.4
# なので 8.2 以上が要る。他の PHP は配布タグの `-php8.x` で選ぶ（image_php_versions_for_series）。
# **.github/workflows/build-image.yml の matrix と揃えること。**
#
# **8.2 は 2026-12-31 でセキュリティサポートが切れる。** 4.3 は対応の上限の 8.3（2027-12-31 まで）を
# 既定にした。4.2 は上流の対応が 8.1 までで、8.2 より上を配っていないので 8.2 のまま
# （4.2 を使い続けるなら、サポートの切れた PHP で動かすことになる）。
image_php_for_series() { # image_php_for_series <系列>
    case "$1" in
        4.2) printf '8.2' ;;
        *)   printf '8.3' ;;
    esac
}

# 系列ごとに配っている PHP（空白区切り）。上流の対応一覧に従う（4.2 の 8.2 は一覧の外だが
# composer の制約には入り、v1.0.0 から配っている）。知らない系列は空を返す。
# **.github/workflows/build-image.yml の matrix と揃えること。**
image_php_versions_for_series() { # image_php_versions_for_series <系列>
    case "$1" in
        4.2) printf '8.1 8.2' ;;
        4.3) printf '8.1 8.2 8.3' ;;
        4.4) printf '8.2 8.3 8.4 8.5' ;;
        *)   printf '' ;;
    esac
}

# その系列で使える PHP か。**知らない系列は通す**（判定できないことで作業を止めない。
# 新しい系列の対応は composer と上流の README が正しい）。
image_php_supported() { # image_php_supported <系列> <PHP>
    local list
    list="$(image_php_versions_for_series "$1")"
    [ -z "$list" ] && return 0
    case " $list " in *" $2 "*) return 0 ;; esac
    return 1
}

# 上げた先（切り替えた先）で使う PHP を決める。
#   <指定> があれば、それがその系列で使えるかだけ見る（使えなければ説明して 1）
#   無ければ <いまの PHP> のまま。**ただし新しい系列で使えないなら、その系列の既定に寄せる**
#   （4.2 の 8.1 から 4.4 へ上げると、4.4 は 8.2 以上なので 8.1 では build も pull もできない）
# 決まった PHP を標準出力へ。説明は標準エラーへ。
image_resolve_php() { # image_resolve_php <系列> <指定（空可）> <いまの PHP（空可）>
    local series="$1" want="$2" cur="$3"
    if [ -n "$want" ]; then
        if image_php_supported "$series" "$want"; then
            printf '%s' "$want"
            return 0
        fi
        echo "エラー: EC-CUBE ${series} 系は PHP ${want} に対応していません（使えるのは: $(image_php_versions_for_series "$series")）。" >&2
        return 1
    fi
    if [ -n "$cur" ] && image_php_supported "$series" "$cur"; then
        printf '%s' "$cur"
        return 0
    fi
    if [ -n "$cur" ]; then
        echo "注意: いまの PHP ${cur} は EC-CUBE ${series} 系で使えないので、$(image_php_for_series "$series") にします（--php=<版> で選べます）。" >&2
    fi
    image_php_for_series "$series"
}

# 配布イメージの参照の PHP を差し替える。タグは「<系列>[-php<版>][-その他]」の形。
#   :4.3-php8.1 + 8.3 → :4.3-php8.3
#   :4.3        + 8.3 → :4.3（8.3 が 4.3 の既定なので短いタグのまま）
#   :4.3        + 8.2 → :4.3-php8.2
#   :4.3-php8.2 + 8.3 → :4.3-php8.3（既定でも -php を外さない。明示した人の意図を残す）
# 系列で始まらないタグは触らない（image_retag_series と同じ理由）。
image_retag_php() { # image_retag_php <参照> <PHP>
    local ref="$1" php="$2" name tag series rest
    case "$ref" in
        *:*) ;;
        *) printf '%s' "$ref"; return 0 ;;
    esac
    name="${ref%:*}"
    tag="${ref##*:}"
    case "$tag" in
        [0-9]*.[0-9]*) ;;
        *) printf '%s' "$ref"; return 0 ;;
    esac
    series="$(printf '%s' "$tag" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
    rest="${tag#"$series"}"
    case "$rest" in
        -php[0-9]*)
            rest="$(printf '%s' "$rest" | sed -E "s/^-php[0-9]+\.[0-9]+/-php${php}/")" ;;
        *)
            [ "$php" = "$(image_php_for_series "$series")" ] || rest="-php${php}${rest}" ;;
    esac
    printf '%s:%s%s' "$name" "$series" "$rest"
}

# 動いているコンテナの PHP（8.3 のような major.minor）を、**イメージの**環境変数から読む。
# 公式の php イメージは ENV PHP_VERSION=8.3.36 を持つ。コンテナ側の環境変数は見ない
# （compose の env_file が .env の PHP_VERSION=8.2 を流し込むと、実物と違う値が読めてしまう）。
# 読めなければ空。
image_php_of_container() { # image_php_of_container <コンテナ ID>
    local img
    img="$(docker inspect --format '{{.Image}}' "$1" 2>/dev/null)" || return 0
    docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$img" 2>/dev/null |
        sed -n 's/^PHP_VERSION=\([0-9]*\.[0-9]*\).*/\1/p' | head -1
}

# 配布イメージの参照から PHP を読む。-php が無ければ系列の既定（短いタグが指すもの）。
# 系列で始まらないタグは空。
image_ref_php() { # image_ref_php <参照>
    local tag series
    case "$1" in *:*) ;; *) return 0 ;; esac
    tag="${1##*:}"
    case "$tag" in [0-9]*.[0-9]*) ;; *) return 0 ;; esac
    case "$tag" in
        *-php[0-9]*) printf '%s' "$tag" | sed -E 's/.*-php([0-9]+\.[0-9]+).*/\1/' ;;
        *) series="$(printf '%s' "$tag" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"; image_php_for_series "$series" ;;
    esac
}

# ── バージョン制約が本当に解決できるかを、build を始める前に確かめる ──
#
# **安定版の無い系列の `~4.4.0` は解決できない。** 4.4 は Packagist に alpha しか無い
# （4.4.0-alpha / 4.4.0-alpha-1。2026-09-25）。create-project は stability を指定しないので
# 安定版しか探さず、build に入ってから composer が
# 「Could not find package ec-cube/ec-cube with version ~4.4.0」で落ちるまで数分かかり、
# .env は書き換わったままになる。ここで 1 秒で止めて、打ち直す形を出す。
#
# **alpha / beta / RC は安定版として数えない。** 以前は「系列で始まる版があるか」だけを見ていたので、
# alpha が出た時点で ~4.4.0 を通してしまい、まさに上の落ち方をしていた。-p1 のような
# パッチ版（4.3.1-p1）は安定版。
#
# 制約の完全な解釈は composer の仕事なのでやらない。見るのは「その系列に何があるか」だけ:
#   版そのもの・@stability 付き      → 通す（4.4.0-alpha-1、~4.4.0@alpha など。composer に任せる）
#   系列に安定版がある              → 通す（~4.3.0 など）
#   系列に安定版が無く、プレリリースか dev がある → 打てる形を並べて止める
#   系列そのものが無い              → ある系列を並べて止める
#
# **問い合わせに 1 つでも失敗したら黙って通す。** 安定版と dev で JSON が別々にあり、片方だけ
# 落ちると「dev が無い」と誤って判定して、正しい指定を止めてしまう（実際に踏んだ）。
# 判定できないことで作業を止めない。
image_check_version() { # image_check_version <制約> [再実行の例] → 解決できなさそうなら説明して 1
    local want="$1" hint="${2:-}" series url stable_json dev_json stable pre dev
    series="$(image_series "$want")"
    case "$series" in [0-9]*.[0-9]*) ;; *) return 0 ;; esac   # 系列を取り出せない形は composer に任せる
    url="https://repo.packagist.org/p2/ec-cube/ec-cube"
    stable_json="$(curl -fsSL --max-time 10 "${url}.json" 2>/dev/null)" || return 0
    dev_json="$(curl -fsSL --max-time 10 "${url}~dev.json" 2>/dev/null)" || return 0
    vers_of() { printf '%s' "$1" | grep -o '"version":"[^"]*"' | cut -d'"' -f4; }
    stable="$(vers_of "$stable_json" | grep -cE "^${series}\.[0-9]+(\.[0-9]+)?(-p[0-9]+)?$" || true)"
    pre="$(vers_of "$stable_json" | grep -iE "^${series}\.[0-9]+.*-(alpha|beta|rc)" | head -1 || true)"
    dev="$(vers_of "$dev_json" | grep -c "^${series}\.x-dev$" || true)"
    [ -n "$(vers_of "$stable_json" | head -1)" ] || return 0   # 中身が読めない → 通す

    case "$want" in
        *@*) return 0 ;;   # stability を明示している。composer に任せる
    esac
    # 版そのもの（4.4.0-alpha-1 など）。あれば通す
    if vers_of "$stable_json" | grep -qxF "$want"; then
        return 0
    fi

    case "$want" in
        *x-dev|dev-*)   # すでに dev 指定。その dev があるかだけ見る
            [ "$dev" != 0 ] && return 0
            {
                echo "エラー: ${want} は上流にありません。"
                printf '       入れられる dev: %s\n' "$(vers_of "$dev_json" | grep -E 'x-dev$' | head -4 | tr '\n' ' ')"
            } >&2
            return 1 ;;
    esac
    [ "$stable" != 0 ] && return 0
    if [ "$dev" != 0 ] || [ -n "$pre" ]; then
        {
            echo "エラー: EC-CUBE ${series} は **まだ正式版がありません**（Packagist に安定版が 1 つも無い）。"
            echo "       ${want} は解決できないので、build を始めずに止めました（.env は変えていません）。"
            echo
            if [ -n "$pre" ]; then
                echo "       プレリリースを入れるなら、版をそのまま書きます（最新: ${pre}）:"
                echo
                echo "         ${hint:-<コマンド>} ${pre}"
                echo
            fi
            if [ "$dev" != 0 ]; then
                echo "       上流の ${series} ブランチの最新を入れるなら:"
                echo
                echo "         ${hint:-<コマンド>} ${series}.x-dev"
                echo
            fi
            echo "       **x-dev は動く的なので、build するたび中身が変わります**（同じ指定でも別のコミットになる）。"
            echo "       本番なら配布イメージのタグを固定するほうが安全です（docs/install.md のタグ表）。"
        } >&2
        return 1
    fi
    {
        echo "エラー: EC-CUBE ${series} は上流にありません（${want} は解決できません）。"
        printf '       入れられる系列: %s\n' "$(vers_of "$stable_json" | sed -n 's/^\([0-9]*\.[0-9]*\)\..*/\1/p' | sort -u -V | tr '\n' ' ')"
    } >&2
    return 1
}

# 参照のタグに入っている系列だけを差し替える。
#   ghcr.io/o/r/ec-cube:4.3-v1.0.0 + 4.4 → ghcr.io/o/r/ec-cube:4.4-v1.0.0
#   ghcr.io/o/r/ec-cube:4.3        + 4.4 → ghcr.io/o/r/ec-cube:4.4
#   ghcr.io/o/r/ec-cube:4.3-php8.1 + 4.4 → ghcr.io/o/r/ec-cube:4.4-php8.1（**無いタグになりうる。**
#     新しい系列にその PHP が無ければ pull で止まるので、.env の -php を新しい系列にあるものへ）
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
