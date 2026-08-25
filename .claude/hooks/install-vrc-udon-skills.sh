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

# 宣言した版は、マーケットプレイスのチェックアウトの HEAD で表す。
market_head() {
    git -C "$state_dir/marketplaces/$MARKETPLACE" rev-parse HEAD 2>/dev/null
}
market_sha=$(market_head)

# 取得元が宣言と食い違えば取り直す。未登録のときもここを通る。
# ref だけでなく repo も見る。移転やフォークへ差し替えたときに
# 古い取得元を使い続けないため。
#
# 取得元の宣言が合っていてもチェックアウトが無ければ取り直す。宣言だけを見て
# 飛ばすと、以後どのセッションでも版を確かめられず、既に入っているプラグインを
# 更新できないまま同じ処理を繰り返す。
# 登録済みのマーケットプレイスへ add を呼んでも何もしないので、
# その場合は update を使う。
if [ "$current" != "$declared" ]; then
    claude plugin marketplace add "$declared" >/dev/null 2>&1
    market_sha=$(market_head)
elif [ -z "$market_sha" ]; then
    claude plugin marketplace update "$MARKETPLACE" >/dev/null 2>&1
    market_sha=$(market_head)
fi

# 取り直しても版が分からなければ、比べる基準が無いので何もしない。
# 上流へ届かないときなどで、この状態では導入も更新もできない。
[ -n "$market_sha" ] || exit 0

plugin_block=""
if [ -f "$installed" ]; then
    plugin_block=$(sed -n "/\"$PLUGIN\"[[:space:]]*:/,/]/p" "$installed")
fi

# 記録されたそれぞれの導入について、宣言した版かどうかを調べる。
#
# 同じプラグインはスコープごとに記録され、user に新しい版、project や local に
# 古い版が併存しうる。どれか一つの一致で終了すると、実際に使われる側が
# 古いまま残る。関係する記録がすべて宣言した版であるときだけ何もしない。
#
# scope 付きの記録は projectPath がこのプロジェクトを指すものだけを見る。
# 他のプロジェクトの導入はこのセッションに影響しないうえ、ここから直せない。
#
# 記録された版は完全な SHA とは限らず短縮されていることもあるため、前方一致で比べる。
found=false
stale_scopes=""
if [ -n "$plugin_block" ]; then
    # 記録を1件1行の「スコープ、プロジェクト、版」へ均す。区切りは US(0x1f)。
    # awkのプログラムはヒアドキュメントの外へ置く。中に置くと $2 や $4 を
    # シェルが先に展開してしまう。
    records=$(printf '%s' "$plugin_block" | awk '
        # 値は JSON の文字列として読み、\" と \\ を復号して返す。
        # 区切り文字で割ると、パスに " を含む場合に途中で切れて
        # 別プロジェクト扱いになる。
        # \n のように文字そのものを表すエスケープは扱わない。
        # パスに制御文字が入ることは想定しない。
        function jsonvalue(line, key,   pos, rest, out, ch, i, escaped) {
            pos = index(line, "\"" key "\"")
            if (pos == 0) {
                return ""
            }
            rest = substr(line, pos + length(key) + 2)
            pos = index(rest, ":")
            rest = substr(rest, pos + 1)
            pos = index(rest, "\"")
            rest = substr(rest, pos + 1)

            out = ""
            escaped = 0
            for (i = 1; i <= length(rest); i++) {
                ch = substr(rest, i, 1)
                if (escaped) {
                    out = out ch
                    escaped = 0
                } else if (ch == "\\") {
                    escaped = 1
                } else if (ch == "\"") {
                    break
                } else {
                    out = out ch
                }
            }
            return out
        }

        /^[[:space:]]*\{/ { scope = ""; path = ""; sha = ""; ver = "" }
        /"scope"/          { scope = jsonvalue($0, "scope") }
        /"projectPath"/    { path  = jsonvalue($0, "projectPath") }
        /"gitCommitSha"/   { sha   = jsonvalue($0, "gitCommitSha") }
        /"version"/        { ver   = jsonvalue($0, "version") }
        /^[[:space:]]*\}/ {
            if (scope != "") {
                printf "%s\037%s\037%s\n", scope, path, (sha != "" ? sha : ver)
            }
        }
    ')

    # 区切りにタブを使わない。タブは IFS の空白文字で、projectPath を持たない
    # 記録のように途中が空だと詰められ、列がずれる。
    while IFS="$(printf '\037')" read -r scope path recorded; do
        [ -n "$scope" ] && [ -n "$recorded" ] || continue
        if [ "$scope" != "user" ] && [ -n "$path" ] && [ "$path" != "$project_dir" ]; then
            continue
        fi
        found=true
        case "$market_sha" in
            "$recorded"*) ;;
            *) stale_scopes="$stale_scopes $scope" ;;
        esac
    done <<EOF
$records
EOF
fi

# 宣言した版がすべてのスコープへ入っていれば何もしない。
if [ "$found" = true ] && [ -z "$stale_scopes" ]; then
    exit 0
fi

if [ "$found" = false ]; then
    if claude plugin install "$PLUGIN" --yes >/dev/null 2>&1; then
        echo "$PLUGIN を導入した。このセッションで使うには /reload-plugins を実行する。"
    fi
    exit 0
fi

# 古い版が残っているスコープだけを更新する。
failed=""
for scope in $stale_scopes; do
    claude plugin update "$PLUGIN" --scope "$scope" --yes >/dev/null 2>&1 || failed="$failed $scope"
done

if [ -z "$failed" ]; then
    echo "$PLUGIN を ${ref:-最新} へ更新した。このセッションで使うには /reload-plugins を実行する。"
else
    echo "$PLUGIN が宣言（${ref:-既定ブランチ}）と食い違っている。次を実行して更新する。"
    # スコープはコマンドごとに 1 つしか指定できないため、1 行にまとめない。
    for scope in $failed; do
        echo "  claude plugin update $PLUGIN --scope $scope"
    done
fi

exit 0
