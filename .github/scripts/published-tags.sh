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
# それを避けるため、zip の無いリリースがあれば、そのタグの release.yml の実行をすべて見る。
# 同じタグで実行が複数になる（リリースを消して作り直した）ことがあるので、最新の一件では足りない。
#   - build ジョブが終わっていなければ、終わるまで待って読み直す
#   - どの実行のどの試行でもタグの検査で落ちていれば、拒まれたリリース（形が違うか、
#     先端でない）で、数えない。検査のステップは通信をしないので、その失敗は拒否に限る
#   - どれかで通っていれば、公開の時点では正しいリリースで、その後に落ちただけである。
#     zip が無いので、直すか消すまで止める
#   - 検査が一度も実行されていない（その前のステップで落ちた、取り消された）ときも、
#     拒まれたか分からないので止める。数えないまま進むと、そのリリースより古い版を後から出す
#   - 実行が無ければ、公開から五分のあいだは待つ。実行は公開の直後に作られるので、
#     五分たっても無いものは待っても付かない。X.Y.Z-testN は prerelease.yml が
#     GITHUB_TOKEN で作って release イベントを起こさないので数えず、正式版は止める
# 実行全体ではなく build ジョブを見るのは、その後の prod デプロイが長く、それまで
# 採番を止める理由が無いためである。
#
# タグの形とリリースの種別（X.Y.Z は正式版、X.Y.Z-testN はプレリリース）が食い違っていれば、
# zip の有無にかかわらず止める。食い違ったものを数えると、release.yml が拒んで prod も
# 出ていない版を起点に採番が進む。
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

  # タグの形とリリースの種別が合っているかを、先に全部見る。
  # X.Y.Z は正式版として、X.Y.Z-testN はプレリリースとして公開されていなければならない。
  # 食い違ったものは、下の一覧にも待つ対象の判定にも通り、正しい版として数えられてしまう。
  # X.Y.Z をプレリリースとして公開すると、release.yml のタグ検査は落ちて prod も出ないのに、
  # 次の自動の版はその先へ進む。人が直すまで採番しない
  MISMATCH=$(jq -r --arg pat "$TAG_PATTERN" '
      .[] | select(.draft | not) | . as $r
      | select($r.tag_name | test($pat))
      | select(if ($r.tag_name | test("-test[1-9][0-9]*$")) then ($r.prerelease | not) else $r.prerelease end)
      | $r.tag_name' "$RELEASES" | tr '\n' ' ')
  if [ -n "$MISMATCH" ]; then
    echo "::error::タグの形とリリースの種別が食い違っている: $MISMATCH。X.Y.Z は正式版、X.Y.Z-testN はプレリリースとして公開する。直すまで採番しない" >&2
    exit 1
  fi

  WAIT_FOR=""
  while read -r TAG PUBLISHED_AT; do
    [ -n "$TAG" ] || continue
    # 同じタグの実行をすべて見る。リリースを消して同じタグで作り直すと実行が複数になり、
    # 最新の一件だけでは、前の実行で検査が通っていた事実を見落とす
    RUN_IDS=$(gh run list --workflow release.yml --event release --branch "$TAG" --limit 100 \
      --json databaseId --jq '.[].databaseId')
    if [ -z "$RUN_IDS" ]; then
      if [ "$PUBLISHED_AT" \> "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)" ]; then
        WAIT_FOR="$TAG（公開の直後で release.yml の実行がまだ無い）"
        break
      fi
      # 実行が無いまま五分を過ぎたもの。
      # X.Y.Z-testN は prerelease.yml が GITHUB_TOKEN で作るので release イベントが起きず、
      # 実行が無いのが普通である。zip が無いのは途中で落ちた自動のプレリリースで、数えない。
      # 正式版は人が公開するので実行が作られる。無いのは、Actions かワークフローが
      # 止まっていたあいだに公開された場合で、zip は後からも付かない。
      # 数えずに進むと、その正式版より古い X.Y.Z-testN を出すので、止める
      case "$TAG" in
        *-test*) continue ;;
      esac
      echo "::error::正式版 $TAG のリリースに zip が無く、release.yml の実行も無い。release.yml を手で流し（version に $TAG、attach を立てる）て zip を付けるか、そのリリースとタグを消すまで採番しない" >&2
      exit 1
    fi

    # すべての実行の、すべての試行の build ジョブを見て、次の三つを集める。
    #   - まだ終わっていない build があるか（待つ）
    #   - タグの検査を通った試行があるか。検査のステップは通信をしない（fetch は前のステップ）
    #     ので、その成否は拒否かどうかに限る。通っていれば、公開の時点では先端だった
    #     正しいリリースで、その後に落ちただけである。zip が無いので、直すか消すまで止める
    #   - 検査が落ちた試行があるか。通った試行が無ければ、拒まれたリリース（形が違うか、
    #     先端でない）で、数えない
    # どれも無いのは、検査が一度も実行されていない場合である。前のステップ（fetch）が落ちた、
    # 取り消された、などで、拒まれたかどうかは分からない。数えずに進むと、zip の無い
    # 正しい正式版より古い版を出すので、止める
    PENDING=""
    VERIFIED=false
    REJECTED=false
    UNVERIFIED=false
    for RUN_ID in $RUN_IDS; do
      ATTEMPTS=$(gh run view "$RUN_ID" --json attempt --jq '.attempt')
      for K in $(seq 1 "$ATTEMPTS"); do
        gh run view "$RUN_ID" --attempt "$K" --json jobs \
          --jq ".jobs[] | select(.name == \"$BUILD_JOB\")" > "$JOB"
        [ -s "$JOB" ] || continue
        if [ "$(jq -r '.status' "$JOB")" != completed ]; then
          PENDING="$RUN_ID"
          continue
        fi
        CONCLUSIONS=$(jq -r --arg step "$VERIFY_STEP" \
          '.steps[] | select(.name == $step) | .conclusion' "$JOB")
        if printf '%s\n' "$CONCLUSIONS" | grep -qx success; then
          VERIFIED=true
        elif printf '%s\n' "$CONCLUSIONS" | grep -qx failure; then
          REJECTED=true
        else
          # 検査まで進んでいない試行。落ちた試行と混ぜると、拒まれたものとして数えない側へ倒れる
          UNVERIFIED=true
        fi
      done
    done
    if [ -n "$PENDING" ] && [ "$VERIFIED" = false ]; then
      WAIT_FOR="$TAG（release.yml の実行 $PENDING の build が終わっていない）"
      break
    fi
    if [ "$VERIFIED" = true ]; then
      echo "::error::$TAG の release.yml はタグの検査を通っているのに、リリースに zip が無い。再実行して zip を付けるか、リリースとタグを消すまで採番しない" >&2
      exit 1
    fi
    # 検査まで進まなかった試行が一つでもあれば、拒まれたかどうかは分からない。
    # 落ちた試行と混ぜて数えないと、打ち直したタグの新しい実行が検査の前で落ちたときに、
    # 古い試行の failure だけを見て拒まれたものとして数えず、それより古い版を出す
    if [ "$UNVERIFIED" = true ]; then
      echo "::error::$TAG の release.yml に、タグの検査まで進まずに落ちた実行がある。拒まれたのかどうか分からないので採番しない。再実行して zip を付けるか、リリースとタグを消す" >&2
      exit 1
    fi
    if [ "$REJECTED" = true ]; then
      continue
    fi
    echo "::error::$TAG の release.yml は、タグの検査まで進まずに落ちている。拒まれたのかどうか分からないので採番しない。再実行して zip を付けるか、リリースとタグを消す" >&2
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
