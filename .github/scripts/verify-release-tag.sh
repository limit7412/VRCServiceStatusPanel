#!/usr/bin/env bash
# リリースのタグが出してよいものかを確かめる（docs/release.md）。
#
#   .github/scripts/verify-release-tag.sh <タグ> <タグが指すコミット> <stable|prerelease>
#
# release.yml（パッケージの公開）と deploy-prod.yml（prod へのデプロイ）の両方から呼ぶ。
# 片方にだけ書くと、パッケージは出たのにデプロイは止まる、あるいはその逆が起きる。
#
# 見るのは二つである。
#   - 形。stable なら X.Y.Z、prerelease なら X.Y.Z-testN。v は付けない。
#     数は 0 か、0 で始まらない十進数に限る。08 のような値は Bash の算術で
#     八進数として読まれ、次の版の計算が止まる。
#     形が違うタグは prerelease.yml が安定版として数えず、次の版がずれる。
#     プレリリースとして公開したものに X.Y.Z を許さないのは、prod へ出ないまま
#     安定版として数えられ、次の採番がその先へ進むためである
#   - タグが指すコミットが master の先端であること。
#     祖先であることの検査では、過去の master のコミットに打ったタグも通り、
#     prod がその時点へ巻き戻る。切り戻しは deploy.yml の手動起動で行う
#
# 先端の比較には origin/master のコミット ID だけが要るので、履歴は要らない。
set -euo pipefail

TAG="${1:?タグを指定すること}"
SHA="${2:?タグが指すコミットを指定すること}"
KIND="${3:?stable か prerelease を指定すること}"

NUM='(0|[1-9][0-9]*)'
case "$KIND" in
  stable)     PATTERN="^$NUM\.$NUM\.$NUM\$" ;;
  prerelease) PATTERN="^$NUM\.$NUM\.$NUM-test[1-9][0-9]*\$" ;;
  *)
    echo "::error::第三引数は stable か prerelease（$KIND）" >&2
    exit 2
    ;;
esac

if ! echo "$TAG" | grep -qE "$PATTERN"; then
  if [ "$KIND" = stable ]; then
    echo "::error::正式版のタグ $TAG は X.Y.Z の形ではない（v も先頭の 0 も付けない。X.Y.Z-testN はプレリリースとして公開する）" >&2
  else
    echo "::error::プレリリースのタグ $TAG は X.Y.Z-testN の形ではない（v も先頭の 0 も付けない。X.Y.Z は正式版として公開する）" >&2
  fi
  exit 1
fi

git fetch --no-tags --depth 1 origin master
MASTER=$(git rev-parse origin/master)
if [ "$SHA" != "$MASTER" ]; then
  echo "::error::タグ $TAG のコミット $SHA が master の先端 $MASTER ではない。master の先端に打ち直す" >&2
  exit 1
fi

echo "タグ $TAG は master の先端 $SHA を指している"
