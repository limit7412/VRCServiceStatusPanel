#!/usr/bin/env bash
# .claude/settings.json が宣言するプラグインを、セッション開始時に導入する。
#
# フォルダを信頼済みなら、マーケットプレイスは Claude Code が宣言から自動で
# 追加する。ただしプラグイン本体は外部ソース由来のため自動では入らない。
# 未信頼の環境や、Claude Code on the web のようにコンテナが毎回作り直される
# 環境では、マーケットプレイス自体も入らない。
# どちらの場合もこのフックが user スコープへ導入し、作業ツリーは汚さない。
#
# 取得元（リポジトリとタグ）の出典は .claude/settings.json だけにする。
# このスクリプトが持つのは、どのプラグインを対象にするかの識別子だけである。

set -u

# 対象のプラグイン。マーケットプレイス名はこの識別子から取る。
PLUGIN="vrc-udon-skills@agent-skills-vrc-udon"
MARKETPLACE="${PLUGIN##*@}"

project_dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
settings="$project_dir/.claude/settings.json"
state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
known="$state_dir/known_marketplaces.json"
installed="$state_dir/installed_plugins.json"

[ -f "$settings" ] || exit 0
command -v claude >/dev/null 2>&1 || exit 0

# 宣言ブロックだけを切り出してから読む。ファイル全体から拾うと、
# 別のマーケットプレイスの repo や ref を混ぜて読んでしまう。
read_source() {
    [ -f "$1" ] || return 0
    sed -n "/\"$MARKETPLACE\"[[:space:]]*:/,/}/p" "$1" |
        sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
        head -1
}

# settings.json がこのプラグインを有効にしていなければ何もしない。
grep -q "\"$PLUGIN\"[[:space:]]*:[[:space:]]*true" "$settings" || exit 0

repo=$(read_source "$settings" repo)
ref=$(read_source "$settings" ref)
[ -n "$repo" ] || exit 0

# ref を省いた宣言も受け付ける。その場合は上流の既定ブランチを追う。
declared="$repo"
[ -n "$ref" ] && declared="$repo@$ref"

known_repo=$(read_source "$known" repo)
known_ref=$(read_source "$known" ref)
current="$known_repo"
[ -n "$known_ref" ] && current="$known_repo@$known_ref"

# 取得元が宣言と食い違えば取り直す。未登録のときもここを通る。
# ref だけでなく repo も見る。移転やフォークへ差し替えたときに
# 古い取得元を使い続けないため。
if [ "$current" != "$declared" ]; then
    claude plugin marketplace add "$declared" >/dev/null 2>&1 || exit 0
fi

# 終了の判断は、マーケットプレイスの ref ではなく導入済みプラグイン自身の版で行う。
# ref だけを見ると、取得し直しに成功して更新に失敗した次の回に、
# 古いプラグインを残したまま「宣言どおり」と誤って判定してしまう。
market_sha=$(git -C "$state_dir/marketplaces/$MARKETPLACE" rev-parse HEAD 2>/dev/null)

plugin_block=""
if [ -f "$installed" ]; then
    plugin_block=$(sed -n "/\"$PLUGIN\"[[:space:]]*:/,/]/p" "$installed")
fi

# 宣言した版が入っていれば何もしない。
if [ -n "$market_sha" ] && [ -n "$plugin_block" ] &&
    printf '%s' "$plugin_block" | grep -q "$market_sha"; then
    exit 0
fi

if [ -z "$plugin_block" ]; then
    if claude plugin install "$PLUGIN" --yes >/dev/null 2>&1; then
        echo "$PLUGIN を導入した。このセッションで使うには /reload-plugins を実行する。"
    fi
    exit 0
fi

# 導入済みだが版が違う場合。フックが入れるのは user スコープなのでそこを更新する。
# project や local スコープで入れている場合は届かないため、手で更新してもらう。
if claude plugin update "$PLUGIN" --scope user --yes >/dev/null 2>&1; then
    echo "$PLUGIN を ${ref:-最新} へ更新した。このセッションで使うには /reload-plugins を実行する。"
else
    echo "$PLUGIN が宣言（${ref:-既定ブランチ}）と食い違っている。claude plugin update $PLUGIN で更新する。"
fi

exit 0
