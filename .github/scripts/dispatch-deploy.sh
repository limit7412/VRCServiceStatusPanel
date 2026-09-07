#!/usr/bin/env bash
# deploy.yml を master の ref で workflow_dispatch として起こし、終わるまで待つ。
# 承認待ちに入ったら、またその後ろに並んだら、待たずに終える（下の注記）。
#
#   .github/scripts/dispatch-deploy.sh <スタック名> <識別子> [期待するコミット]
#
# deploy-dev.yml と release.yml から呼ぶ。
# 環境変数 GH_TOKEN（actions: write と checks: read を持つ GITHUB_TOKEN）と GH_REPO が要る。
# actions: write は起こすのと、五時間たったときや親が取り消されたときに取り消すのに使う。
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

# 起こした実行を識別子で探す。見つからなければ空
find_run() {
  gh run list --workflow deploy.yml --event workflow_dispatch --branch master \
    --created ">=$SINCE" --limit 20 --json databaseId,displayTitle \
    --jq "map(select(.displayTitle | endswith(\"[$DISPATCH_ID]\"))) | .[0].databaseId // empty"
}

# 起こした後に親のジョブが取り消されたら、起こした実行も取り消してから終える。
# 起こした実行は独立していて、こちらが止まっても続き、親を止めた後に prod が変わる。
# 起こしてから実行が見つかるまでのあいだに取り消されたときも、識別子で探して取り消す。
# 取り消しはランナーが INT を送り、少し待って TERM、さらに待って KILL を送るので、
# 探すのは短く切り上げる。承認待ちで手を離した後は、こちらは既に終わっているので掛からない
RUN_ID=""
on_cancel() {
  trap - INT TERM
  if [ -z "$RUN_ID" ]; then
    for _ in 1 2 3; do
      RUN_ID=$(find_run || true)
      [ -n "$RUN_ID" ] && break
      sleep 2
    done
  fi
  if [ -n "$RUN_ID" ]; then
    echo "::warning::親のジョブが取り消された。起こした deploy の実行 $RUN_ID も取り消す" >&2
    gh run cancel "$RUN_ID" || true
  else
    echo "::warning::親のジョブが取り消されたが、起こした deploy の実行がまだ見つからない。Actions の deploy で [$DISPATCH_ID] を探し、手で取り消す" >&2
  fi
  exit 130
}
trap on_cancel INT TERM

gh workflow run deploy.yml --ref master \
  -f "stack=$STACK" -f "expected_sha=$EXPECTED_SHA" -f "dispatch_id=$DISPATCH_ID"
echo "deploy.yml を master の ref で起こした（stack=$STACK、expected_sha=${EXPECTED_SHA:-なし}、dispatch_id=$DISPATCH_ID）"

for _ in $(seq 1 12); do
  sleep 5
  RUN_ID=$(find_run)
  [ -n "$RUN_ID" ] && break
done
if [ -z "$RUN_ID" ]; then
  echo "::error::起こした deploy の実行が一分たっても見つからない。Actions の deploy を見る" >&2
  exit 1
fi
echo "deploy の実行: https://github.com/$GH_REPO/actions/runs/$RUN_ID"

# 終わるまで待つ。gh run watch は使わず、状態を読んで待つ。
# environment prod に required reviewers があると、起こした実行は承認まで waiting で止まる。
# watch はそれも待ち続け、承認が六時間を超えると、こちらのジョブが先に実行時間の上限で落ちる。
# 起こした実行は残るので、親は失敗のまま後から承認されて出る、という食い違いになる。
# 承認待ち（wait timer も同じ状態になる）に入ったら追うのをやめ、その先の結果は
# 起こした実行で見る。dev には承認が無いので、ここへは来ない。
#
# 同じスタックの前の実行が承認待ちのあいだは、この実行は concurrency の群の空きを待ち、
# 状態は waiting ではなく queued や pending のままになる。それも同じに扱い、
# 同じスタックの前の実行に waiting のものがあれば追うのをやめる。
# どちらにも当たらずに五時間たったとき（ランナー不足で並んだまま、pulumi up が終わらない）は、
# 上限で落ちる前に起こした実行を取り消して失敗にする。承認待ちと違って、そのまま手を離すと
# 親が緑のまま後から失敗する、または親の後で出る、という食い違いになる。通常は来ない

# 実行の名前は deploy.yml の run-name のとおり「deploy <スタック名>」か
# 「deploy <スタック名> [<識別子>]」で、その二つの形だけを同じスタックと見る。
# 前方一致にすると dev2 のような名前のスタックも拾う
SAME_STACK="(.displayTitle == \"deploy $STACK\" or (.displayTitle | startswith(\"deploy $STACK [\")))"

hand_off() {
  echo "::notice::deploy の実行 $RUN_ID は $1。ここでは待たず、その先の結果はその実行で見る"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "deploy の実行 $RUN_ID は $1。その先の結果は https://github.com/$GH_REPO/actions/runs/$RUN_ID で見る" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
}

STARTED=$(date +%s)
while :; do
  STATUS=$(gh run view "$RUN_ID" --json status --jq '.status')
  case "$STATUS" in
    completed)
      break
      ;;
    waiting)
      hand_off "environment の保護規則（承認か wait timer）で止まっている"
      ;;
    in_progress)
      ;;
    *)
      # queued、pending、requested。群の空きを待っている先が承認待ちなら、いつ空くか分からない
      BLOCKED=$(gh run list --workflow deploy.yml --status waiting --limit 20 --json databaseId,displayTitle \
        --jq "map(select(.databaseId < $RUN_ID and $SAME_STACK)) | length")
      if [ "$BLOCKED" -gt 0 ]; then
        hand_off "同じスタックの前の実行が承認待ちで止まっていて、その後ろに並んでいる"
      fi
      ;;
  esac
  if [ $(( $(date +%s) - STARTED )) -ge $(( 5 * 60 * 60 )) ]; then
    echo "::error::deploy の実行 $RUN_ID は五時間たっても終わっていない（状態 $STATUS）。取り消して失敗にする。pulumi up の途中なら state のロックが残ることがあり、その場合は pulumi cancel で外す" >&2
    gh run cancel "$RUN_ID" || true
    exit 1
  fi
  sleep 20
done
CONCLUSION=$(gh run view "$RUN_ID" --json conclusion --jq '.conclusion')
case "$CONCLUSION" in
  success)
    echo "deploy の実行 $RUN_ID は成功した"
    ;;
  cancelled)
    if [ "${CANCELLED_OK:-false}" = true ]; then
      # 同じスタックへ、この実行より後に起こされた実行があるか
      NEWER=$(gh run list --workflow deploy.yml --event workflow_dispatch --branch master \
        --limit 20 --json databaseId,displayTitle \
        --jq "map(select(.databaseId > $RUN_ID and $SAME_STACK)) | length")
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
