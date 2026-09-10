#!/usr/bin/env bash
# リリースのタグが出してよいものかを確かめる（docs/release.md）。
#
#   .github/scripts/verify-release-tag.sh <タグ> <タグが指すコミット> <stable|prerelease>
#
# release.yml（パッケージの公開）から呼ぶ。prod へのデプロイは release.yml が起こす
# deploy.yml で行い、そこで別に確かめる（docs/release.md）。
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
# origin/master は呼ぶ側が先に fetch しておく。ここでは通信をしない。
# release.yml のこのステップの失敗は、prerelease.yml が呼ぶ published-tags.sh が
# 「タグが拒まれた」と読む。通信の失敗が同じステップで起きると、拒まれたのと
# 見分けが付かず、正しい正式版を数えずに採番が進む
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

if ! MASTER=$(git rev-parse --verify -q origin/master); then
  echo "::error::origin/master が無い。呼ぶ側で先に fetch する（release.yml の fetch master）" >&2
  exit 2
fi
if [ "$SHA" != "$MASTER" ]; then
  echo "::error::タグ $TAG のコミット $SHA が master の先端 $MASTER ではない。master の先端に打ち直す" >&2
  exit 1
fi

echo "タグ $TAG は master の先端 $SHA を指している"
