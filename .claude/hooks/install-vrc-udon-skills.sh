#!/usr/bin/env bash
# .claude/settings.json が宣言するプラグインを、セッション開始時に導入する。
#
# フォルダを信頼済みなら、マーケットプレイスは Claude Code が宣言から自動で
# 追加する。ただしプラグイン本体は外部ソース由来のため自動では入らない。
# 未信頼の環境や、Claude Code on the web のようにコンテナが毎回作り直される
# 環境では、マーケットプレイス自体も入らない。
# どちらの場合もこのフックが user スコープへ導入し、作業ツリーは汚さない。

set -u

project_dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
settings="$project_dir/.claude/settings.json"
state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"

[ -f "$settings" ] || exit 0
command -v claude >/dev/null 2>&1 || exit 0

# 宣言の出典は .claude/settings.json だけにする。
# マーケットプレイスを増やしたらこの抽出を見直す。
[ "$(grep -c '"repo"' "$settings")" = "1" ] || exit 0

plugin=$(sed -n 's/.*"\([^"]*@[^"]*\)"[[:space:]]*:[[:space:]]*true.*/\1/p' "$settings" | head -1)
repo=$(sed -n 's/.*"repo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings" | head -1)
ref=$(sed -n 's/.*"ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings" | head -1)

[ -n "$plugin" ] && [ -n "$repo" ] || exit 0

# 導入済みなら触らない
if [ -f "$state_dir/installed_plugins.json" ] &&
    grep -q "\"$plugin\"" "$state_dir/installed_plugins.json"; then
    exit 0
fi

marketplace="${plugin##*@}"
source="$repo"
[ -n "$ref" ] && source="$repo@$ref"

if ! { [ -f "$state_dir/known_marketplaces.json" ] &&
        grep -q "\"$marketplace\"" "$state_dir/known_marketplaces.json"; }; then
    claude plugin marketplace add "$source" >/dev/null 2>&1 || exit 0
fi

if claude plugin install "$plugin" --yes >/dev/null 2>&1; then
    echo "$plugin を導入した。このセッションで使うには /reload-plugins を実行する。"
fi

exit 0
