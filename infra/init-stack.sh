#!/usr/bin/env bash
# スタックを作り、仕様書 11.7 の値を入れる。
#
# CI から流すには Pulumi.<スタック名>.yaml が要る（#12）。まっさらなランナーには
# このファイルが無く、無いまま pulumi up を叩くと最初の config.require で止まる。
# Pulumi の設定は state ではなくこのファイルに入るためである。
#
# GitHub Actions からも流すなら、本体と infra/oidc/ を同じスタック名で作る。
# 二つがずれると、dev のデプロイロールでは prod を触れないまま CI が
# AccessDenied で止まる。手元からだけ流すなら infra/oidc/ は作らない。
#
# 二度目以降に流すと、いま入っている値を既定として見せる。Enter で通せば
# そのまま残る。空で答えても消えないので、消すときは pulumi config rm を使う。
#
# 使い方:
#   infra/init-stack.sh dev
#
# 値は一つずつ聞く。省略できるものは空のまま Enter で飛ばせる。
# 秘密の値は標準入力から渡すので、コマンドラインにも履歴にも残らない。
#
# 出来上がった二つの Pulumi.<スタック名>.yaml は commit する。--secret で入れた値は
# 暗号文として記録されるため平文では残らない。復号には PULUMI_CONFIG_PASSPHRASE が要る。

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

stack="${1:-}"
case "$stack" in
    "" | -h | --help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        [ -n "$stack" ] && exit 0
        exit 2
        ;;
esac

# 名前の規則は infra/src/settings.ts と infra/oidc/index.ts に合わせる。
# ここで弾かないと、二つのスタックと十四の設定を作ったあと pulumi up が
# 名前の検証で必ず止まる。使えないスタックだけが残る。
MAX_STACK_NAME=16

if ! printf '%s' "$stack" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
    echo "スタック名 \"$stack\" は物理名に使えない。小文字、数字、ハイフンだけで、先頭と末尾は小文字か数字にする" >&2
    exit 2
fi

if [ "${#stack}" -gt "$MAX_STACK_NAME" ]; then
    echo "スタック名 \"$stack\" が長い（${#stack} 文字）。${MAX_STACK_NAME} 文字までにする" >&2
    exit 2
fi

if ! command -v pulumi > /dev/null 2>&1; then
    echo "pulumi が無い。https://www.pulumi.com/docs/install/ から入れる" >&2
    exit 1
fi

# パスフレーズは state の中の secret を復号する鍵である。
# 失うと state を読めなくなるので、控えを残してもらう（仕様書 9.1）。
if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ] && [ -z "${PULUMI_CONFIG_PASSPHRASE_FILE:-}" ]; then
    echo "PULUMI_CONFIG_PASSPHRASE が要る。これを失うと state の secret を読めなくなるので、控えを残すこと" >&2
    exit 1
fi

# 入力が尽きたら止める。省略ではなく中断だからである。
# 省略できない値を聞いている途中で Ctrl-D を押されたときに、
# 同じ警告を出し続ける無限ループにならないようにする。
abort_on_eof() {
    printf '\n' >&2
    echo "入力が尽きたので中断する。" >&2
    echo "作りかけのスタックを消すなら、作った分だけ次を実行する" >&2
    echo "  pulumi -C $here stack rm $stack" >&2
    if [ "$use_ci" = yes ]; then
        echo "  pulumi -C $here/oidc stack rm $stack" >&2
    fi
    exit 1
}

# 一問だけ聞く。答えは ANSWER に入れる。既定があれば、空の答えはそれで埋める。
# EOF なら 1 を返す。呼び出し側は abort_on_eof で止める。
#
# 秘密の値は端末へ出さない。履歴に残らなくても、打っている最中の画面と
# セッションの録画には残るためである。
ask() {
    local label="$1" default="${2:-}" hidden="${3:-}"

    ANSWER=""

    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi

    if [ -n "$hidden" ]; then
        # -s は改行を出さないので、こちらで出す
        read -rs ANSWER || return 1
        printf '\n' >&2
    else
        read -r ANSWER || return 1
    fi

    [ -n "$ANSWER" ] || ANSWER="$default"
    return 0
}

# いま設定に入っている値。無ければ空を返す。
#
# 二度目以降の実行で、入っている値を既定として見せるために使う。
# 見せずに聞くと、Enter で通したときに何が残ったのか分からない。
# 空で答えても消えはしない。消したいときは pulumi config rm を使う。
current_config() {
    local dir="$1" key="$2"

    pulumi -C "$dir" config get --stack "$stack" "$key" 2> /dev/null || true
}

# 省略できない値。空で返ってきたら聞き直す。
set_required() {
    local dir="$1" key="$2" label="$3" default="${4:-}" existing=""

    existing=$(current_config "$dir" "$key")
    [ -z "$existing" ] || default="$existing"

    while :; do
        ask "$label" "$default" || abort_on_eof
        [ -n "$ANSWER" ] && break
        echo "  ここは省略できない" >&2
    done

    pulumi -C "$dir" config set --stack "$stack" "$key" "$ANSWER"
}

# 省略できる値。空なら設定へ書かない。
set_optional() {
    local dir="$1" key="$2" label="$3" default="${4:-}" existing=""

    existing=$(current_config "$dir" "$key")
    [ -z "$existing" ] || default="$existing"

    ask "$label" "$default" || abort_on_eof
    if [ -z "$ANSWER" ]; then
        return 0
    fi

    pulumi -C "$dir" config set --stack "$stack" "$key" "$ANSWER"
}

# 設定にその値が入っているか。中身は取り出さない。
#
# 秘密の値について「入っているか」だけを知りたいときに使う。
# current_config は復号した平文を返すので、こちらでは呼ばない。
has_config() {
    local dir="$1" key="$2"

    pulumi -C "$dir" config get --stack "$stack" "$key" > /dev/null 2>&1
}

# 秘密の値。打っている最中も画面に出さず、標準入力から渡して暗号文として記録する。
#
# 二度目以降は Enter で今の値のままにできる。既定として見せることはしない。
# 見せれば画面に出てしまい、隠して聞いた意味が無くなる。
set_secret() {
    local dir="$1" key="$2" label="$3" keep=""

    if has_config "$dir" "$key"; then
        keep="$label（Enter で今の値のまま）"
    fi

    while :; do
        ask "${keep:-$label}" "" hidden || abort_on_eof
        [ -n "$ANSWER" ] && break
        [ -z "$keep" ] || return 0
        echo "  ここは省略できない" >&2
    done

    printf '%s' "$ANSWER" | pulumi -C "$dir" config set --stack "$stack" --secret "$key"
}

# Layer は ARN と版を一組で入れる（仕様書 7.3）。
# 片方だけだと、deploy.sh の事前確認は ARN しか見ないので通ってしまい、
# settings.ts が両方を require しているため pulumi up で止まる。
set_layer() {
    local arn="" version=""

    while :; do
        ask "yt-dlp Layer の ARN（未発行なら空のまま）" || abort_on_eof
        arn="$ANSWER"

        ask "その Layer に入れた yt-dlp の版（同上）" || abort_on_eof
        version="$ANSWER"

        if [ -n "$arn" ] && [ -z "$version" ]; then
            echo "  ARN と版は一組で入れる。版だけ空にはできない" >&2
            continue
        fi

        if [ -z "$arn" ] && [ -n "$version" ]; then
            echo "  ARN と版は一組で入れる。ARN だけ空にはできない" >&2
            continue
        fi

        break
    done

    # 両方とも空なら、まだ発行していないということである。
    # deploy.sh --ytdlp <版> が発行と同時に両方を入れる。
    if [ -z "$arn" ]; then
        return 0
    fi

    pulumi -C "$here" config set --stack "$stack" ytdlpLayerArn "$arn"
    pulumi -C "$here" config set --stack "$stack" ytdlpLayerVersion "$version"
}

create_stack() {
    local dir="$1"

    # 既にあれば作らない。二度目以降は値の入れ直しになる。
    pulumi -C "$dir" stack select --create "$stack" --secrets-provider passphrase > /dev/null
}

# infra/oidc/ は CI の入口である。手元からだけ流すなら要らない。
# 作らせると、使わない OIDC プロバイダと IAM ロールを作る権限まで要ることになる。
# 本体の workloadBoundaryArn は省略できるので、無くても手元からは流せる。
use_ci=no
ask "GitHub Actions からもデプロイするか（y/n）" "y" || abort_on_eof
case "$ANSWER" in
    y | Y | yes | Yes) use_ci=yes ;;
    *) use_ci=no ;;
esac

echo
echo "=== $stack を作る ==="
create_stack "$here"
[ "$use_ci" = no ] || create_stack "$here/oidc"

# 二度目の実行で Enter を押したときに、既定のリージョンで上書きしない。
# 別のリージョンで作ってあると、AWS のリソースが置き換わり、
# 発行済みの Layer とも食い違う。
region_default=$(current_config "$here" aws:region)
[ -n "$region_default" ] || region_default="ap-northeast-1"

ask "AWS のリージョン（仕様書 5.1）" "$region_default" || abort_on_eof
pulumi -C "$here" config set --stack "$stack" aws:region "$ANSWER"
[ "$use_ci" = no ] || pulumi -C "$here/oidc" config set --stack "$stack" aws:region "$ANSWER"

echo
echo "--- Cloudflare（仕様書 6） ---"
set_secret "$here" cloudflare:apiToken "API トークン（要る権限は README の「Cloudflare の API トークン」）"
set_required "$here" cloudflareAccountId "アカウント ID"
set_required "$here" deliveryZoneId "配信ドメインのゾーン ID"
set_required "$here" deliveryHost "配信ホスト名（例 status.example.com）"
set_optional "$here" bucketLocation "バケットの場所" "apac"
set_optional "$here" publicBucket "配信バケット名（既定 qazx7412-vrc-service-status-panel-$stack-public）"
set_optional "$here" stateBucket "内部バケット名（既定 qazx7412-vrc-service-status-panel-$stack-state）"

echo
echo "--- 合成監視の対象（仕様書 3.3） ---"
set_required "$here" youtubeProbeVideoId "YouTube の固定動画 ID"
set_required "$here" boothProbeItemId "BOOTH の商品 ID"

echo
echo "--- 集約サーバー（仕様書 7.3、11.7） ---"
set_layer
set_secret "$here" githubDispatchToken "Layer 再ビルドを起動する GitHub のトークン"
set_secret "$here" alertWebhookUrl "失敗時のアラート送信先 URL"

if [ "$use_ci" = yes ]; then
    echo
    echo "--- GitHub Actions からの入口（仕様書 9.1） ---"
    set_required "$here/oidc" githubRepository "デプロイを許すリポジトリ" "limit7412/VRCServiceStatusPanel"
    set_optional "$here/oidc" githubOidcProviderArn "既にある OIDC プロバイダの ARN（無ければ空のまま）"
fi

# 案内は絶対パスで出す。README の手順は infra/ から実行するので、
# infra/oidc のような相対パスを出すと、そこからは infra/infra/oidc を指してしまう。
echo
echo "=== ここまでで出来たもの ==="
echo "  $here/Pulumi.$stack.yaml"
[ "$use_ci" = no ] || echo "  $here/oidc/Pulumi.$stack.yaml"
echo
echo "次にやること"
echo "  1. 出来た Pulumi.$stack.yaml を commit する（#12）"
echo "  2. Layer を発行して本体を流す"
echo "       $here/deploy.sh --ytdlp <版>"

if [ "$use_ci" = yes ]; then
    echo
    echo "GitHub Actions から流すには、2 の前に次も行う"
    echo "  a. 入口と権限境界を作る"
    echo "       npm ci --prefix $here/oidc"
    echo "       pulumi -C $here/oidc up"
    echo "     infra/oidc/ は package-lock を別に持つ。infra/ の npm ci では入らない"
    echo "  b. その workloadBoundaryArn を本体へ入れる"
    echo "       pulumi -C $here config set --stack $stack workloadBoundaryArn \\"
    echo "         \"\$(pulumi -C $here/oidc stack output workloadBoundaryArn)\""
    echo "  c. 次の五つを GitHub の Secrets へ登録する"
    echo "       AWS_DEPLOY_ROLE_ARN"
    echo "         pulumi -C $here/oidc stack output githubDeployRoleArn"
    echo "       PULUMI_CONFIG_PASSPHRASE        いま使ったもの"
    echo "       PULUMI_STATE_ACCESS_KEY_ID      状態の置き場所（R2）の鍵"
    echo "       PULUMI_STATE_SECRET_ACCESS_KEY  同上"
    echo "       CLOUDFLARE_API_TOKEN            Cloudflare の API トークン"
    echo "     どれが何に使われるかは README の「ワークフローでの受け取り」にある"
fi
