#!/usr/bin/env bash
# 次に作るプレリリースの版を決める（仕様書 9.2、docs/release.md）。
#
#   .github/scripts/next-prerelease-version.sh <安定版タグが無いときの次期バージョン>
#
# タグの一覧から決めるので、fetch-depth: 0 で checkout した作業ツリーで呼ぶ。
# 標準出力に X.Y.Z-testN を一行出す。
#
# 次期バージョンは、次の二つの大きいほうである。
#   - 最新の安定版タグ X.Y.Z のパッチを一つ上げた X.Y.(Z+1)
#   - 既にある X.Y.Z-testN のうち、いちばん新しい X.Y.Z
# 後者があるのは、パッチ以外を上げるプレリリース（例 0.2.0-test1）を手で作った後に
# master への取り込みが続いたとき、そこで 0.1.1-test1 を作らないためである。
# 手で始めた系列を継いで 0.2.0-test2 にする。
# 安定版より古い系列（0.0.9-test1 のような）は前者に負けるので、自然に外れる。
#
# 安定版タグが一つも無いときは、引数の版を前者の代わりに使う。
#
# package.json の version はリリース時にタグから上書きする運用なので、起点には使えない。
set -euo pipefail

FIRST_VERSION="${1:?安定版タグが無いときの次期バージョンを指定すること（例: 0.1.0）}"

STABLE_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
PRERELEASE_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+-test[0-9]+$'

# grep は一致が無いと 1 を返す。無いのは正常なので、pipefail の中でも止めない
STABLE=$(git tag --list | grep -E "$STABLE_PATTERN" | sort -V | tail -n 1 || true)
if [ -n "$STABLE" ]; then
  NEXT_PATCH="${STABLE%.*}.$(( ${STABLE##*.} + 1 ))"
else
  echo "安定版タグ（X.Y.Z）が無いので、次期バージョンの起点を $FIRST_VERSION とする" >&2
  NEXT_PATCH="$FIRST_VERSION"
fi

OPEN_BASES=$(git tag --list | grep -E "$PRERELEASE_PATTERN" | sed -E 's/-test[0-9]+$//' | sort -uV || true)
NEXT=$(printf '%s\n' "$NEXT_PATCH" $OPEN_BASES | sort -V | tail -n 1)

# 同じ次期バージョンの -testN があれば N を進める。先頭の 0 を落としてから数として比べる
MAX_N=$(git tag --list "${NEXT}-test*" | sed -nE 's/^.*-test0*([0-9]+)$/\1/p' | sort -n | tail -n 1 || true)
N=$(( ${MAX_N:-0} + 1 ))

echo "${NEXT}-test${N}"
