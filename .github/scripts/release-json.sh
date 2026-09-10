#!/usr/bin/env bash
# タグに対応するリリースの JSON を出す（prerelease.yml から呼ぶ）。
#
#   .github/scripts/release-json.sh <タグ>
#
# 環境変数 GH_TOKEN と GH_REPO が要る。
# リリースが無ければ何も出さずに 0 で終える。照会そのものが失敗したときは 1 で終える。
#
# gh の終了コードは、リリースが無い（404）ときも通信や認証で失敗したときも 1 になる。
# 呼ぶ側はこの二つを分けなければならない。分けないと、照会が失敗しただけで「無い」と読み、
# 人が公開したリリースのタグを作りかけとして消したり、下書きのまま公開を飛ばしたりする。
# 標準エラーの HTTP 404 で見分ける（gh は「gh: Not Found (HTTP 404)」の形で出す）。
set -euo pipefail

TAG="${1:?タグを指定すること}"
: "${GH_TOKEN:?GH_TOKEN が要る}"
: "${GH_REPO:?GH_REPO が要る}"

ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

if gh api "repos/$GH_REPO/releases/tags/$TAG" 2>"$ERR"; then
  exit 0
fi
if grep -q 'HTTP 404' "$ERR"; then
  exit 0
fi
cat "$ERR" >&2
echo "::error::リリース $TAG を照会できない。GitHub の応答は上のとおり" >&2
exit 1
