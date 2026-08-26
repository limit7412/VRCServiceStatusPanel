#!/usr/bin/env bash
# 手元からのデプロイをひと通り流す。
#
# 手で並べると、バイナリのビルド、Layer の発行、ARN の書き写し、pulumi up の
# 四つになる。途中で書き写しを挟むため、Layer を作り直したのに ARN を
# 入れ替え忘れる、という抜け方をする（#8）。ここではその二つを必ず一緒に更新する。
#
# commit はしない。出来上がった Pulumi.<スタック名>.yaml をどう残すかは
# 人が決めることなので、最後に案内するだけにしてある。
#
# 使い方:
#   infra/deploy.sh                        今の設定のまま作り直す
#   infra/deploy.sh --ytdlp 2025.09.26     Layer をこの版で発行し直してから流す
#   infra/deploy.sh --yes                  以降の引数は pulumi up へ渡る
#
# R2 をバックエンドにしている場合、AWS の鍵は DEPLOY_AWS_* で渡す
# （infra/README.md の「AWS の資格情報を分ける」）。

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

ytdlp_version=""
pulumi_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --ytdlp)
            if [ $# -lt 2 ]; then
                echo "--ytdlp には版が要る" >&2
                exit 2
            fi
            ytdlp_version="$2"
            shift 2
            ;;
        -h | --help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *)
            pulumi_args+=("$1")
            shift
            ;;
    esac
done

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "$1 が要る" >&2
        exit 1
    fi
}

need pulumi
need npm
need docker
need zip

cd "$here"

stack=$(pulumi stack --show-name 2>/dev/null || true)
if [ -z "$stack" ]; then
    echo "スタックが選ばれていない。pulumi stack select <名前> を先に実行する" >&2
    exit 1
fi
echo "==> スタック: $stack"

# 設定の読み出し。未設定なら pulumi config get は非ゼロで終わる。
config_get() {
    pulumi config get "$1" 2>/dev/null || true
}

if [ ! -d node_modules ]; then
    echo "==> 依存を入れる"
    npm ci
fi

echo "==> bootstrap.zip を作る"
"$repo/backend/build.sh"

# Layer は版を指定したときだけ発行し直す。
#
# ARN と版は必ず一緒に更新する。片方だけだと、実行時の版の比較が
# 食い違いを出し続けて repository_dispatch が繰り返し起動する（#8）。
if [ -n "$ytdlp_version" ]; then
    need aws

    # Layer は関数と同じリージョンに無いと結べない。CLI の既定に任せると、
    # 未設定なら止まり、別のリージョンなら pulumi up まで気づけない。
    # 既定は src/settings.ts と揃える。
    region=$(config_get aws:region)
    region="${region:-ap-northeast-1}"

    echo "==> Layer の zip を作る（yt-dlp $ytdlp_version）"
    "$repo/backend/layer/build.sh" "$ytdlp_version" "" "$here/ytdlp-layer.zip"

    # aws コマンドは Pulumi の写し替えを知らない。鍵をその場で AWS_* へ移す。
    # DEPLOY_AWS_* が無い環境（R2 をバックエンドにしていない）では
    # そのままの AWS_* が使われる。
    echo "==> Layer を発行する（$region）"
    layer_arn=$(
        env \
            ${DEPLOY_AWS_ACCESS_KEY_ID:+AWS_ACCESS_KEY_ID="$DEPLOY_AWS_ACCESS_KEY_ID"} \
            ${DEPLOY_AWS_SECRET_ACCESS_KEY:+AWS_SECRET_ACCESS_KEY="$DEPLOY_AWS_SECRET_ACCESS_KEY"} \
            ${DEPLOY_AWS_SESSION_TOKEN:+AWS_SESSION_TOKEN="$DEPLOY_AWS_SESSION_TOKEN"} \
            aws lambda publish-layer-version \
            --region "$region" \
            --layer-name qazx7412-vrc-service-status-panel-ytdlp \
            --zip-file "fileb://$here/ytdlp-layer.zip" \
            --compatible-runtimes provided.al2023 \
            --compatible-architectures arm64 \
            --query LayerVersionArn --output text
    )

    if [ -z "$layer_arn" ] || [ "$layer_arn" = "None" ]; then
        echo "Layer の ARN を受け取れなかった" >&2
        exit 1
    fi

    echo "==> ARN と版を設定へ入れる"
    echo "    $layer_arn"
    pulumi config set ytdlpLayerArn "$layer_arn"
    pulumi config set ytdlpLayerVersion "$ytdlp_version"
else
    have_arn=$(config_get ytdlpLayerArn)
    if [ -z "$have_arn" ]; then
        echo "ytdlpLayerArn が未設定である。初回は --ytdlp <版> を付けて実行する" >&2
        exit 1
    fi
    echo "==> Layer はそのまま使う（$(config_get ytdlpLayerVersion)）"
fi

echo "==> pulumi up"
pulumi up "${pulumi_args[@]+"${pulumi_args[@]}"}"

cat <<EOF

できあがり。設定が変わっていれば commit する。

    git -C "$repo" add infra/Pulumi.$stack.yaml
EOF
