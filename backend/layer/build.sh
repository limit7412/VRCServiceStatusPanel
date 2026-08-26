#!/usr/bin/env bash
# yt-dlp と QuickJS を取得して Lambda Layer の zip を作る（仕様書 7.1）。
#
# 展開先は /opt なので、zip の中は bin/ 直下に置く。
#   /opt/bin/yt-dlp_linux
#   /opt/bin/qjs
#
# yt-dlp は公式のスタンドアロン実行ファイル（PyInstaller 版、EJS 同梱）を使う。
# コンテナイメージは使わない。
#
# 版は引数で受け取る。yt-dlp の版は VRChat クライアントの同梱版に合わせるため、
# ここでは決めない（仕様書 7.3）。
#
# 使い方:
#   backend/layer/build.sh <yt-dlpの版> [QuickJSの版] [出力先]
#   backend/layer/build.sh 2025.09.26

set -euo pipefail

YTDLP_VERSION="${1:-}"
QUICKJS_VERSION="${2:-v0.10.1}"
OUTPUT="${3:-$PWD/ytdlp-layer.zip}"

# 出力先は zip を呼ぶ前に絶対パスへ直す。
# zip は一時ディレクトリへ cd してから実行するので、相対パスのままだと
# 一時ディレクトリの中に成果物ができ、trap でそれごと消えてしまう。
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac

if [ -z "$YTDLP_VERSION" ]; then
    echo "usage: $0 <yt-dlp version> [quickjs version] [output zip]" >&2
    echo "  例: $0 2025.09.26" >&2
    exit 2
fi

for command in curl zip; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "$command が要る" >&2
        exit 1
    fi
done

# Lambda は arm64 で動かす（仕様書 5.1）。x86_64 のバイナリを入れても動かない。
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_linux_aarch64"
QUICKJS_URL="https://github.com/quickjs-ng/quickjs/releases/download/$QUICKJS_VERSION/qjs-linux-aarch64"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

echo "yt-dlp $YTDLP_VERSION を取得する"
curl -fsSL -o "$work/bin/yt-dlp_linux" "$YTDLP_URL"

echo "QuickJS $QUICKJS_VERSION を取得する"
curl -fsSL -o "$work/bin/qjs" "$QUICKJS_URL"

chmod +x "$work/bin/yt-dlp_linux" "$work/bin/qjs"

# 版が変わっても zip の中身が同じなら同じ zip になるよう、時刻を固定する。
# 発行のたびに中身が同じ Layer を作らないため。
find "$work" -exec touch -t 200001010000 {} +

rm -f "$OUTPUT"
(cd "$work" && zip -q -X -r "$OUTPUT" bin)

echo "できあがり: $OUTPUT"

# 一覧は中身の確認のためだけに出す。
# unzip は curl や zip と別のパッケージで、入っていない環境がある。
# set -e のもとでこれを必須にすると、zip ができているのに
# 非ゼロで終わってしまう。
if command -v unzip >/dev/null 2>&1; then
    unzip -l "$OUTPUT"
fi
