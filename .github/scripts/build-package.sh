#!/usr/bin/env bash
# VPM パッケージの zip を作る（仕様書 9.2）。
#
# prerelease.yml と release.yml の両方から呼ぶ。
# 片方のワークフローだけに zip の作り方を書くと、プレリリースと正式版で
# 中身の違うパッケージができる。ここに一つだけ置き、両方がこれを呼ぶ。
#
#   .github/scripts/build-package.sh <版> [出力先]
#
# 出力は一つで、リリースの files: "*.zip" がそのまま拾う。
#   com.qazx7412.vrcservicestatuspanel-<版>.zip
#
# 起点は unity/Packages/com.qazx7412.vrcservicestatuspanel/ である。
# VPM の zip は package.json がルートに来る必要があり、リポジトリ直下を
# そのまま固めることはできない（仕様書 10）。
#
# 含めるのは package.json、Runtime/、Editor/ と、それらの .meta である。
# Tests/ は入れない。
# .meta は除外しない。Runtime/ の UdonSharp のアセンブリ資産は asmdef を GUID で
# 参照していて、.meta を落とすとインポート時に GUID が振り直され、この参照が切れる。
#
# prerelease.yml の changes ジョブが見る対象パスは、ここで固める中身と揃えること。
# ずれると、中身の同じプレリリースが増えるか、中身が変わったのに作られないかの
# どちらかが起きる。
set -euo pipefail

VERSION="${1:?版を指定すること（例: 0.1.0、0.1.1-test3）}"
OUTPUT_DIR="${2:-.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/unity/Packages/com.qazx7412.vrcservicestatuspanel"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

cd "$PACKAGE_DIR"

PACKAGE_NAME="$(jq -r '.name' package.json)"

# package.json の version はリリース時にタグから上書きする運用で、
# リポジトリ上の値は起点に使わない（仕様書 9.2）。渡された版を書き込む。
# 字下げは元のファイルと同じ 4 にし、version 以外の差分を出さない。
jq --indent 4 --arg version "$VERSION" '.version = $version' package.json > package.json.tmp
mv package.json.tmp package.json

# Editor/ はまだ無い。作られたら自然に入るよう、在るものだけ並べる。
# 無い名前を zip に渡すと止まる。
# ディレクトリがあるのに .meta が無いのは、Unity で開いていない状態なので止める。
# .meta 無しで配ると、入れた側で GUID が振り直される。
ENTRIES=(package.json package.json.meta)
for DIR in Runtime Editor; do
  [ -d "$DIR" ] || continue
  if [ ! -f "$DIR.meta" ]; then
    echo "::error::$DIR/ はあるのに $DIR.meta が無い" >&2
    exit 1
  fi
  ENTRIES+=("$DIR" "$DIR.meta")
done

ZIP="$OUTPUT_DIR/${PACKAGE_NAME}-${VERSION}.zip"
rm -f "$ZIP"
zip -q -r "$ZIP" "${ENTRIES[@]}"

echo "Created: $ZIP"
unzip -l "$ZIP"
