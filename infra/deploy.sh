#!/usr/bin/env bash
# 手元からのデプロイをひと通り流す。
#
# 手で並べると、バイナリのビルド、Layer の zip の用意、pulumi up の三つになる。
# Layer そのものは Pulumi が持つので、発行と関数への反映は up の中で揃う（#8）。
#
# commit はしない。出来上がった Pulumi.<スタック名>.yaml をどう残すかは
# 人が決めることなので、最後に案内するだけにしてある。
#
# 使い方:
#   infra/deploy.sh                        今の設定のまま流す
#   infra/deploy.sh --ytdlp 2025.09.26     yt-dlp の版を入れ替えてから流す
#   infra/deploy.sh --yes                  以降の引数は pulumi up へ渡る
#
# 相手のスタックは pulumi stack select で先に決める。--stack は受け付けない。
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
        # --stack を通すと、pulumi up だけがそちらを見て、設定の読み書きは
        # 選ばれているスタックを見る。dev の版で作った zip を prod の Layer として
        # 発行しながら、description と YTDLP_VERSION には prod の版が入る、
        # という食い違いになる。相手は一つに決める。
        --stack | --stack=* | -s | -s?*)
            echo "--stack は受け付けない。pulumi stack select <名前> で先に決める" >&2
            exit 2
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
need curl

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

# 版を渡されたら、まず設定を書き換える。
# 以降は設定を唯一の出どころとして扱うので、この一行で up まで揃う。
if [ -n "$ytdlp_version" ]; then
    echo "==> yt-dlp の版を入れ替える（$ytdlp_version）"
    pulumi config set ytdlpVersion "$ytdlp_version"
fi

# Layer の zip は毎回用意する。
#
# Pulumi が Layer を持つので、up はこのファイルを読んでハッシュを取る。
# 無いと止まる。build.sh は同じ版の zip が既にあれば何もしないので、
# 取り直しが走るのは版を変えたときだけである。
want_version=$(config_get ytdlpVersion)
if [ -z "$want_version" ]; then
    echo "ytdlpVersion が未設定である。--ytdlp <版> を付けて実行するか、init-stack.sh で入れる" >&2
    exit 1
fi

echo "==> Layer の zip を用意する（yt-dlp $want_version）"
"$repo/backend/layer/build.sh" "$want_version" "" "$repo/backend/ytdlp-layer.zip"

echo "==> pulumi up"
pulumi up "${pulumi_args[@]+"${pulumi_args[@]}"}"

cat <<EOF

できあがり。設定が変わっていれば commit する。

    git -C "$repo" add infra/Pulumi.$stack.yaml
EOF
