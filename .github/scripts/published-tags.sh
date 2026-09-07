#!/usr/bin/env bash
# 採番に使う「公開の済んだタグ」の一覧を作る（next-prerelease-version.sh の第二引数）。
#
#   .github/scripts/published-tags.sh <パッケージ名> <出力先>
#
# prerelease.yml から呼ぶ。環境変数 GH_TOKEN（actions: read を持つ GITHUB_TOKEN）と GH_REPO が要る。
# 出力は一行に一つのタグで、パッケージの zip（<パッケージ名>-<タグ>.zip）の付いた
# リリースのあるタグに限る。master の過去のコミットに打って公開を拒まれたタグ（zip が
# 付かない）や、別のファイルを手で添付しただけのリリースは入らない。
#
# 正式版（X.Y.Z）は人がリリースを公開し、zip は release.yml が後から付ける。
# 公開から添付までのあいだにこれを読むと、その正式版は zip が無いとして一覧から外れ、
# 採番がその正式版より古い X.Y.Z-testN を出す。SemVer では正式版より古く、利用者は
# 新しい test 版として取れない。
# それを避けるため、zip の無い正式版のリリースがあれば、その release.yml の build ジョブが
# 終わるまで待ってから読み直す。実行がまだ見つからないリリースも、公開から五分のあいだは
# 待つ。実行は公開の直後に作られるので、五分たっても無いものは、ワークフローを置く前の
# リリースか配信されなかったもので、待っても付かない。
# build ジョブが終わっても zip が無いものは、先端でないとして拒まれたリリースで、数えない。
# 実行全体ではなく build ジョブを見るのは、その後の prod デプロイが長く、それまで
# 採番を止める理由が無いためである。
#
# concurrency の群を release.yml と共有して直列にする形は採らない。
# 群で待てる実行は一件で、後から来た実行が待っている実行を取り消す。
# 取り込みが続いたときに、待っていた正式版の build が取り消され、zip の無い正式版が残る。
set -euo pipefail

PACKAGE_NAME="${1:?パッケージ名を指定すること}"
OUTPUT="${2:?出力先を指定すること}"
: "${GH_TOKEN:?GH_TOKEN が要る}"
: "${GH_REPO:?GH_REPO が要る}"

# release.yml の build ジョブの表示名。release.yml の jobs.build.name と揃える
BUILD_JOB="build package"
NUM='(0|[1-9][0-9]*)'
STABLE_PATTERN="^$NUM\\.$NUM\\.$NUM\$"
# 待つ上限。build ジョブは数分で終わる
DEADLINE=$(( $(date +%s) + 30 * 60 ))
RELEASES=$(mktemp)
trap 'rm -f "$RELEASES"' EXIT

while :; do
  # gh api --paginate はページごとの配列を続けて出す。jq は配列ごとに処理するので、そのまま読める
  gh api --paginate "repos/$GH_REPO/releases" > "$RELEASES"

  # zip の無い正式版のリリース。下書きは公開されていないので見ない
  WAIT_FOR=""
  while read -r TAG PUBLISHED_AT; do
    [ -n "$TAG" ] || continue
    RUN_ID=$(gh run list --workflow release.yml --event release --branch "$TAG" --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty')
    if [ -n "$RUN_ID" ]; then
      BUILDING=$(gh run view "$RUN_ID" --json jobs \
        --jq "[.jobs[] | select(.name == \"$BUILD_JOB\" and .status != \"completed\")] | length")
      if [ "$BUILDING" -gt 0 ]; then
        WAIT_FOR="$TAG（release.yml の実行 $RUN_ID の build が終わっていない）"
        break
      fi
      # build が終わって zip が無いのは拒まれたリリース。数えない
      continue
    fi
    if [ "$PUBLISHED_AT" \> "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)" ]; then
      WAIT_FOR="$TAG（公開の直後で release.yml の実行がまだ無い）"
      break
    fi
  done < <(jq -r --arg pkg "$PACKAGE_NAME" --arg pat "$STABLE_PATTERN" '
      .[] | select(.draft | not) | . as $r
      | select($r.tag_name | test($pat))
      | select(any($r.assets[]; .name == ($pkg + "-" + $r.tag_name + ".zip")) | not)
      | "\($r.tag_name) \($r.published_at)"' "$RELEASES")

  if [ -z "$WAIT_FOR" ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "::error::正式版 $WAIT_FOR の zip を三十分待ったが付かない。その release.yml の実行を見る" >&2
    exit 1
  fi
  echo "正式版 $WAIT_FOR。zip が付くまで待つ"
  sleep 20
done

jq -r --arg pkg "$PACKAGE_NAME" \
  '.[] | . as $r | select(any($r.assets[]; .name == ($pkg + "-" + $r.tag_name + ".zip"))) | .tag_name' \
  "$RELEASES" > "$OUTPUT"
echo "公開の済んだタグ: $(wc -l < "$OUTPUT") 件"
