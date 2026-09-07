#!/usr/bin/env bash
# deploy.yml を master の ref で workflow_dispatch として起こし、終わるまで待つ。
#
#   .github/scripts/dispatch-deploy.sh <スタック名> <識別子> [期待するコミット]
#
# deploy-dev.yml と release.yml から呼ぶ。
# 環境変数 GH_TOKEN（actions: write と checks: read を持つ GITHUB_TOKEN）と GH_REPO が要る。
# CANCELLED_OK=true を渡すと、起こした実行が concurrency の群で後続に置き換えられて
# 取り消されたときは 0 で終える。dev ではそれは「後から起こした実行が代わりに出す」ことを
# 意味し、失敗ではない。同じスタックへ後から起こした実行が見つからない取り消し
# （人が Actions から止めたなど）は、後続が無く dev が更新されていないので失敗にする。
#
# workflow_call で呼ばずに起こすのは、呼ばれたワークフローが呼んだ側のコミットの定義で
# 動くためである。master の ref で起こせば、定義も内容もその時点の master の先端になる。
# GITHUB_TOKEN で起こした workflow_dispatch は実行を作る（GITHUB_TOKEN が起こすイベントの
# うち workflow_dispatch と repository_dispatch だけが例外である）。
#
# 起こした実行の ID は同期的には返らない。gh run list は起動の入力では絞れないので、
# 識別子を dispatch_id で渡し、deploy.yml がそれを実行の名前に付け、一覧の名前で探す。
# 同じコミットで直前に手で流した実行と取り違えない。
set -euo pipefail

STACK="${1:?スタック名を指定すること}"
DISPATCH_ID="${2:?識別子を指定すること}"
EXPECTED_SHA="${3:-}"
: "${GH_TOKEN:?GH_TOKEN が要る}"
: "${GH_REPO:?GH_REPO が要る}"

# 探す範囲の下限。時計のずれを見て一分前から
SINCE=$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%S+00:00)

gh workflow run deploy.yml --ref master \
  -f "stack=$STACK" -f "expected_sha=$EXPECTED_SHA" -f "dispatch_id=$DISPATCH_ID"
echo "deploy.yml を master の ref で起こした（stack=$STACK、expected_sha=${EXPECTED_SHA:-なし}、dispatch_id=$DISPATCH_ID）"

RUN_ID=""
for _ in $(seq 1 12); do
  sleep 5
  RUN_ID=$(gh run list --workflow deploy.yml --event workflow_dispatch --branch master \
    --created ">=$SINCE" --limit 20 --json databaseId,displayTitle \
    --jq "map(select(.displayTitle | endswith(\"[$DISPATCH_ID]\"))) | .[0].databaseId // empty")
  [ -n "$RUN_ID" ] && break
done
if [ -z "$RUN_ID" ]; then
  echo "::error::起こした deploy の実行が一分たっても見つからない。Actions の deploy を見る" >&2
  exit 1
fi
echo "deploy の実行: https://github.com/$GH_REPO/actions/runs/$RUN_ID"

# 終わるまで待つ。経過の出力は長いので捨て、結果だけを見る
gh run watch "$RUN_ID" >/dev/null
CONCLUSION=$(gh run view "$RUN_ID" --json conclusion --jq '.conclusion')
case "$CONCLUSION" in
  success)
    echo "deploy の実行 $RUN_ID は成功した"
    ;;
  cancelled)
    if [ "${CANCELLED_OK:-false}" = true ]; then
      # 同じスタックへ、この実行より後に起こされた実行があるか。
      # 実行の名前は deploy.yml の run-name のとおり「deploy <スタック名>」か
      # 「deploy <スタック名> [<識別子>]」で、その二つの形だけを同じスタックと見る。
      # 前方一致にすると dev2 のような名前のスタックも拾う
      NEWER=$(gh run list --workflow deploy.yml --event workflow_dispatch --branch master \
        --limit 20 --json databaseId,displayTitle \
        --jq "map(select(.databaseId > $RUN_ID and (.displayTitle == \"deploy $STACK\" or (.displayTitle | startswith(\"deploy $STACK [\"))))) | length")
      if [ "$NEWER" -gt 0 ]; then
        echo "::notice::deploy の実行 $RUN_ID は取り消された。同じスタックへ後から起こした実行が代わりに出す"
        exit 0
      fi
    fi
    echo "::error::deploy の実行 $RUN_ID は取り消され、同じスタックへ後から起こした実行も無い" >&2
    exit 1
    ;;
  *)
    echo "::error::deploy の実行 $RUN_ID は $CONCLUSION で終わった" >&2
    exit 1
    ;;
esac
