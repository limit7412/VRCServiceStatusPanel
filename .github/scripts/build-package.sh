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
# 資産と .meta が対になっていること、シンボリックリンクが無いことを確かめてから固める。
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

# Runtime/ はパッケージの本体で、無ければ止める。
# 消したり動かしたりした変更もプレリリースの対象に入るので、黙って続けると
# コードを一つも含まない zip が公開される。
# Editor/ はまだ無い。作られたら自然に入るよう、在るときだけ並べる。
# ディレクトリがあるのに .meta が無いのは、Unity で開いていない状態なので止める。
# .meta 無しで配ると、入れた側で GUID が振り直される。
# package.json と package.json.meta は、無ければここで止める。zip -r は無い入力を警告で
# 済ませ、他の入力があれば成功するので、並べただけでは欠けたまま公開される
for FILE in package.json package.json.meta; do
  if [ ! -f "$FILE" ]; then
    echo "::error::$PACKAGE_DIR に $FILE が無い" >&2
    exit 1
  fi
done
ENTRIES=(package.json package.json.meta)
for DIR in Runtime Editor; do
  if [ ! -d "$DIR" ]; then
    if [ "$DIR" = Runtime ]; then
      echo "::error::$PACKAGE_DIR に Runtime/ が無い。パッケージの本体なので zip を作らない" >&2
      exit 1
    fi
    continue
  fi
  if [ ! -f "$DIR.meta" ]; then
    echo "::error::$DIR/ はあるのに $DIR.meta が無い" >&2
    exit 1
  fi
  ENTRIES+=("$DIR" "$DIR.meta")
done

# 配下の資産にも .meta が対になっていることを見る。Runtime.meta だけあっても、
# 配下の asmdef の .meta が無ければ、入れた側でその GUID が振り直され、
# 同梱するアセンブリ資産の sourceAssembly の参照が切れる。
# 資産に .meta が無いのも、.meta だけが残っているのも、Unity で開かずに手で触った状態なので止める
MISSING=""
for DIR in Runtime Editor; do
  [ -d "$DIR" ] || continue
  while IFS= read -r ASSET; do
    [ -e "$ASSET.meta" ] || MISSING="$MISSING $ASSET.meta"
  done < <(find "$DIR" -mindepth 1 -not -name '*.meta')
  while IFS= read -r META; do
    [ -e "${META%.meta}" ] || MISSING="$MISSING ${META%.meta}"
  done < <(find "$DIR" -mindepth 1 -name '*.meta')
done
if [ -n "$MISSING" ]; then
  echo "::error::資産と .meta が対になっていない。無いもの:$MISSING" >&2
  exit 1
fi

# シンボリックリンクは入れない。zip -r はリンクを格納せず参照先を辿るので、
# パッケージの外（.git など、checkout が置いた認証情報を含む）を指すリンクが
# 取り込まれると、その中身が公開される
LINKS=$(find "${ENTRIES[@]}" -type l)
if [ -n "$LINKS" ]; then
  echo "::error::シンボリックリンクはパッケージに入れられない: $(echo "$LINKS" | tr '\n' ' ')" >&2
  exit 1
fi

ZIP="$OUTPUT_DIR/${PACKAGE_NAME}-${VERSION}.zip"
rm -f "$ZIP"
# -MM は、無い入力や読めない入力を警告ではなく失敗にする。上で確かめてあるが、重ねておく
zip -q -r -MM "$ZIP" "${ENTRIES[@]}"

echo "Created: $ZIP"
unzip -l "$ZIP"
