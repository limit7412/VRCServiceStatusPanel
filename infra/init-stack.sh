#!/usr/bin/env bash
# スタックを作り、仕様書 11.7 の値を入れる。
#
# CI から流すには Pulumi.<スタック名>.yaml が要る（#12）。まっさらなランナーには
# このファイルが無く、無いまま pulumi up を叩くと最初の config.require で止まる。
# Pulumi の設定は state ではなくこのファイルに入るためである。
#
# 本体と infra/oidc/ を同じスタック名で作る。二つがずれると、dev のデプロイロールでは
# prod を触れないまま CI が AccessDenied で止まる。
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

# 一問だけ聞く。既定があれば、空の答えはそれで埋める。
ask() {
    local label="$1" default="${2:-}" answer=""

    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi

    read -r answer || answer=""
    [ -n "$answer" ] || answer="$default"
    printf '%s' "$answer"
}

# 省略できない値。空で返ってきたら聞き直す。
set_required() {
    local dir="$1" key="$2" label="$3" default="${4:-}" answer=""

    while [ -z "$answer" ]; do
        answer=$(ask "$label" "$default")
        [ -n "$answer" ] || echo "  ここは省略できない" >&2
    done

    pulumi -C "$dir" config set --stack "$stack" "$key" "$answer"
}

# 省略できる値。空なら設定へ書かない。
set_optional() {
    local dir="$1" key="$2" label="$3" default="${4:-}" answer=""

    answer=$(ask "$label" "$default")
    if [ -z "$answer" ]; then
        return 0
    fi

    pulumi -C "$dir" config set --stack "$stack" "$key" "$answer"
}

# 秘密の値。標準入力から渡して暗号文として記録する。
set_secret() {
    local dir="$1" key="$2" label="$3" answer=""

    while [ -z "$answer" ]; do
        answer=$(ask "$label")
        [ -n "$answer" ] || echo "  ここは省略できない" >&2
    done

    printf '%s' "$answer" | pulumi -C "$dir" config set --stack "$stack" --secret "$key"
}

create_stack() {
    local dir="$1"

    # 既にあれば作らない。二度目以降は値の入れ直しになる。
    pulumi -C "$dir" stack select --create "$stack" --secrets-provider passphrase > /dev/null
}

echo "=== $stack を作る ==="
create_stack "$here"
create_stack "$here/oidc"

region=$(ask "AWS のリージョン（仕様書 5.1）" "ap-northeast-1")
pulumi -C "$here" config set --stack "$stack" aws:region "$region"
pulumi -C "$here/oidc" config set --stack "$stack" aws:region "$region"

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
set_optional "$here" ytdlpLayerArn "yt-dlp Layer の ARN（未発行なら空のまま）"
set_optional "$here" ytdlpLayerVersion "その Layer に入れた yt-dlp の版（同上）"
set_secret "$here" githubDispatchToken "Layer 再ビルドを起動する GitHub のトークン"
set_secret "$here" alertWebhookUrl "失敗時のアラート送信先 URL"

echo
echo "--- GitHub Actions からの入口（仕様書 9.1） ---"
set_required "$here/oidc" githubRepository "デプロイを許すリポジトリ" "limit7412/VRCServiceStatusPanel"
set_optional "$here/oidc" githubOidcProviderArn "既にある OIDC プロバイダの ARN（無ければ空のまま）"

echo
echo "=== ここまでで出来たもの ==="
echo "  infra/Pulumi.$stack.yaml"
echo "  infra/oidc/Pulumi.$stack.yaml"
echo
echo "次にやること"
echo "  1. 二つの Pulumi.$stack.yaml を commit する（#12）"
echo "  2. pulumi -C infra/oidc up で入口と権限境界を作る"
echo "  3. その workloadBoundaryArn を本体へ入れる"
echo "       pulumi -C infra/oidc stack output workloadBoundaryArn"
echo "       pulumi -C infra config set --stack $stack workloadBoundaryArn <出力された ARN>"
echo "  4. infra/deploy.sh --ytdlp <版> で Layer を発行し、本体を流す"
echo "  5. PULUMI_CONFIG_PASSPHRASE を GitHub の Secrets へ登録する"
