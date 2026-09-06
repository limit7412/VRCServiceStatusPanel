#!/usr/bin/env bash
# 次に作るプレリリースの版を決める（仕様書 9.2、docs/release.md）。
#
#   .github/scripts/next-prerelease-version.sh <安定版タグが無いときの次期バージョン>
#
# HEAD（master の先端）から辿れるタグだけを見る。
# 別のブランチに打たれたタグは数えない。release.yml が master の先端でないとして
# 公開を拒んだタグが残っても、それで採番が飛ばないようにするためである。
# fetch-depth: 0 で master を checkout した作業ツリーで呼ぶ。
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

# 数は 0 か、0 で始まらない十進数に限る（verify-release-tag.sh と同じ）。
# 08 のような値は下の算術で八進数として読まれて止まる
NUM='(0|[1-9][0-9]*)'
STABLE_PATTERN="^$NUM\.$NUM\.$NUM\$"
PRERELEASE_PATTERN="^$NUM\.$NUM\.$NUM-test[1-9][0-9]*\$"

# grep は一致が無いと 1 を返す。無いのは正常なので、pipefail の中でも止めない
STABLE=$(git tag --merged HEAD | grep -E "$STABLE_PATTERN" | sort -V | tail -n 1 || true)
if [ -n "$STABLE" ]; then
  NEXT_PATCH="${STABLE%.*}.$(( 10#${STABLE##*.} + 1 ))"
else
  echo "安定版タグ（X.Y.Z）が無いので、次期バージョンの起点を $FIRST_VERSION とする" >&2
  NEXT_PATCH="$FIRST_VERSION"
fi

OPEN_BASES=$(git tag --merged HEAD | grep -E "$PRERELEASE_PATTERN" | sed -E 's/-test[1-9][0-9]*$//' | sort -uV || true)
NEXT=$(printf '%s\n' "$NEXT_PATCH" $OPEN_BASES | sort -V | tail -n 1)

# 同じ次期バージョンの -testN があれば N を進める。形に合うものだけを数える
MAX_N=$(git tag --merged HEAD --list "${NEXT}-test*" | grep -E "$PRERELEASE_PATTERN" | sed -nE 's/^.*-test([1-9][0-9]*)$/\1/p' | sort -n | tail -n 1 || true)
N=$(( 10#${MAX_N:-0} + 1 ))

echo "${NEXT}-test${N}"
