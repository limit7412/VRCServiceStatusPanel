#!/usr/bin/env bash
# 採番に使う「公開の済んだタグ」の一覧を作る（next-prerelease-version.sh の第二引数）。
#
#   .github/scripts/published-tags.sh <パッケージ名> <出力先>
#
# prerelease.yml から呼ぶ。環境変数 GH_TOKEN（actions: read を持つ GITHUB_TOKEN）と GH_REPO が要る。
# 出力は一行に一つのタグで、下書きでないリリースのうち、パッケージの zip
# （<パッケージ名>-<タグ>.zip）の付いたものに限る。
# master の過去のコミットに打って公開を拒まれたタグ（zip が付かない）や、別のファイルを
# 手で添付しただけのリリースは入らない。下書きは書き込み権限のトークンだと API が返すが、
# 公開されていないので入れない。
#
# 人が公開したリリース（正式版 X.Y.Z と、系列を始めるために手で作った X.Y.Z-testN）の zip は、
# release.yml が公開の後で付ける。公開から添付までのあいだにこれを読むと、そのタグは
# zip が無いとして一覧から外れ、採番がそれより古い版を出す。正式版なら SemVer で正式版より
# 古い X.Y.Z-testN、手で始めた系列なら旧系列の版で、利用者は新しい test 版として取れない。
# それを避けるため、zip の無いリリースがあれば、そのタグの release.yml の実行を見る。
#   - build ジョブが終わっていなければ、終わるまで待って読み直す
#   - build ジョブがタグの検査で落ちていれば、先端でないとして拒まれたリリースで、数えない
#   - それ以外で build ジョブが成功していない（検査の後で落ちた、取り消された）か、
#     成功しているのに zip が無い（後から消された）なら、止める。
#     数えないまま進むと、そのリリースより古い版を後から出す。直すか消すまで採番しない
#   - 実行が無ければ、公開から五分のあいだは待つ。実行は公開の直後に作られるので、
#     五分たっても無いものは待っても付かない（ワークフローを置く前のリリースや、
#     prerelease.yml が GITHUB_TOKEN で作った失敗したプレリリース。後者は release
#     イベントを起こさず、再実行で拾う）。数えない
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

# release.yml の build ジョブとタグを検査するステップの表示名。release.yml と揃える
BUILD_JOB="build package"
VERIFY_STEP="verify the release tag"
NUM='(0|[1-9][0-9]*)'
TAG_PATTERN="^$NUM\\.$NUM\\.$NUM(-test[1-9][0-9]*)?\$"
# 待つ上限。build ジョブは数分で終わる
DEADLINE=$(( $(date +%s) + 30 * 60 ))
RELEASES=$(mktemp)
JOB=$(mktemp)
trap 'rm -f "$RELEASES" "$JOB"' EXIT

while :; do
  # gh api --paginate はページごとの配列を続けて出す。jq は配列ごとに処理するので、そのまま読める
  gh api --paginate "repos/$GH_REPO/releases" > "$RELEASES"

  WAIT_FOR=""
  while read -r TAG PUBLISHED_AT; do
    [ -n "$TAG" ] || continue
    RUN_ID=$(gh run list --workflow release.yml --event release --branch "$TAG" --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty')
    if [ -z "$RUN_ID" ]; then
      if [ "$PUBLISHED_AT" \> "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)" ]; then
        WAIT_FOR="$TAG（公開の直後で release.yml の実行がまだ無い）"
        break
      fi
      continue
    fi
    gh run view "$RUN_ID" --json jobs --jq ".jobs[] | select(.name == \"$BUILD_JOB\")" > "$JOB"
    if [ ! -s "$JOB" ] || [ "$(jq -r '.status' "$JOB")" != completed ]; then
      WAIT_FOR="$TAG（release.yml の実行 $RUN_ID の build が終わっていない）"
      break
    fi
    if [ "$(jq -r '.conclusion' "$JOB")" = success ]; then
      echo "::error::$TAG の release.yml の実行 $RUN_ID は成功しているのに、リリースに zip が無い。zip を戻すかリリースを消すまで採番しない" >&2
      exit 1
    fi
    if [ "$(jq -r --arg step "$VERIFY_STEP" '.steps[] | select(.name == $step) | .conclusion' "$JOB")" = failure ]; then
      # 先端でないとして拒まれたリリース。数えない
      continue
    fi
    echo "::error::$TAG の release.yml の実行 $RUN_ID はタグの検査の後で落ちている。再実行して zip を付けるか、リリースとタグを消すまで採番しない" >&2
    exit 1
  done < <(jq -r --arg pkg "$PACKAGE_NAME" --arg pat "$TAG_PATTERN" '
      .[] | select(.draft | not) | . as $r
      | select($r.tag_name | test($pat))
      | select(any($r.assets[]; .name == ($pkg + "-" + $r.tag_name + ".zip")) | not)
      | "\($r.tag_name) \($r.published_at)"' "$RELEASES")

  if [ -z "$WAIT_FOR" ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "::error::$WAIT_FOR の zip を三十分待ったが付かない。その release.yml の実行を見る" >&2
    exit 1
  fi
  echo "$WAIT_FOR。zip が付くまで待つ"
  sleep 20
done

jq -r --arg pkg "$PACKAGE_NAME" \
  '.[] | select(.draft | not) | . as $r
   | select(any($r.assets[]; .name == ($pkg + "-" + $r.tag_name + ".zip"))) | .tag_name' \
  "$RELEASES" > "$OUTPUT"
echo "公開の済んだタグ: $(wc -l < "$OUTPUT") 件"
