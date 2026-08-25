#!/usr/bin/env bash
# .claude/settings.json が宣言するプラグインを、セッション開始時に導入する。
#
# フォルダを信頼済みなら、マーケットプレイスは Claude Code が宣言から自動で
# 追加する。ただしプラグイン本体は外部ソース由来のため自動では入らない。
# 未信頼の環境や、Claude Code on the web のようにコンテナが毎回作り直される
# 環境では、マーケットプレイス自体も入らない。
# どちらの場合もこのフックが user スコープへ導入し、作業ツリーは汚さない。
#
# 版の出典は .claude/settings.json だけにする。このスクリプトが持つのは
# マーケットプレイス名だけで、リポジトリ名とタグは持たない。

set -u

# 対象のマーケットプレイス。settings.json から読む対象をこの名前で絞る。
# 他のマーケットプレイスやプラグインを settings.json へ足しても巻き込まない。
MARKETPLACE="agent-skills-vrc-udon"

project_dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
settings="$project_dir/.claude/settings.json"
state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"

[ -f "$settings" ] || exit 0
command -v claude >/dev/null 2>&1 || exit 0

# 宣言ブロックだけを切り出してから読む。ファイル全体から拾うと、
# 別のマーケットプレイスの repo や ref を混ぜて読んでしまう。
read_declared() {
    sed -n "/\"$MARKETPLACE\"[[:space:]]*:/,/}/p" "$1" |
        sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
        head -1
}

# このマーケットプレイスに属する有効なプラグインを選ぶ。
plugin=$(sed -n "s/.*\"\([^\"]*@$MARKETPLACE\)\"[[:space:]]*:[[:space:]]*true.*/\1/p" "$settings" | head -1)
repo=$(read_declared "$settings" repo)
ref=$(read_declared "$settings" ref)

[ -n "$plugin" ] && [ -n "$repo" ] || exit 0

source="$repo"
[ -n "$ref" ] && source="$repo@$ref"

known="$state_dir/known_marketplaces.json"
installed="$state_dir/installed_plugins.json"

marketplace_known=false
installed_ref=""
if [ -f "$known" ] && grep -q "\"$MARKETPLACE\"" "$known"; then
    marketplace_known=true
    installed_ref=$(read_declared "$known" ref)
fi

plugin_installed=false
if [ -f "$installed" ] && grep -q "\"$plugin\"" "$installed"; then
    plugin_installed=true
fi

# 宣言どおりに入っていれば何もしない。
if [ "$marketplace_known" = true ] && [ "$plugin_installed" = true ] &&
    [ "$installed_ref" = "$ref" ]; then
    exit 0
fi

# 未登録のときと、settings.json の ref が変わったときに取り直す。
# marketplace add は宣言を上書きして参照先を解決し直すため、
# ref を上げたあとも古いタグのまま使い続けることがない。
if [ "$marketplace_known" = false ] || [ "$installed_ref" != "$ref" ]; then
    claude plugin marketplace add "$source" >/dev/null 2>&1 || exit 0
fi

if [ "$plugin_installed" = false ]; then
    if claude plugin install "$plugin" --yes >/dev/null 2>&1; then
        echo "$plugin を導入した。このセッションで使うには /reload-plugins を実行する。"
    fi
    exit 0
fi

# 導入済みで ref だけが変わった場合。フックが入れるのは user スコープなので
# そこを更新する。project や local スコープで入れている場合は届かないため、
# 失敗したら手で更新してもらう。
if claude plugin update "$plugin" --scope user --yes >/dev/null 2>&1; then
    echo "$plugin を $ref へ更新した。このセッションで使うには /reload-plugins を実行する。"
else
    echo "$plugin の宣言が $ref に変わっている。claude plugin update $plugin で更新する。"
fi

exit 0
