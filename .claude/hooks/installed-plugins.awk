# installed_plugins.json から、対象プラグインの記録を
# 「スコープ US プロジェクト US 版」の行として書き出す。
#
# 文字列と構造を区別して走査する。区切り文字や括弧で割ると、
# パスに " や ] を含む記録で途中で切れ、別プロジェクト扱いになる。
# \" \\ \/ と制御文字のエスケープを復号する。\u はそのまま残す。

function isspace(ch) {
    return ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
}

# pos から始まる JSON 文字列を読む。復号した値を value へ、
# 次の位置を nextpos へ返す。
function readstring(s, pos,   ch, out, code) {
    pos++            # 開きの " を飛ばす
    out = ""
    while (pos <= length(s)) {
        ch = substr(s, pos, 1)
        if (ch == "\\") {
            pos++
            code = substr(s, pos, 1)
            if (code == "n")      { out = out "\n" }
            else if (code == "t") { out = out "\t" }
            else if (code == "r") { out = out "\r" }
            else if (code == "b") { out = out "\b" }
            else if (code == "f") { out = out "\f" }
            else if (code == "u") { out = out "\\u"; }   # 文字化は行わない
            else                  { out = out code }     # " \ / はそのまま
            pos++
        } else if (ch == "\"") {
            value = out
            nextpos = pos + 1
            return
        } else {
            out = out ch
            pos++
        }
    }
    value = out
    nextpos = pos
}

# pos の位置にある値を読み飛ばし、次の位置を nextpos へ返す。
function skipvalue(s, pos,   ch, depth) {
    ch = substr(s, pos, 1)
    if (ch == "\"") {
        readstring(s, pos)
        return
    }
    if (ch == "{" || ch == "[") {
        depth = 0
        while (pos <= length(s)) {
            ch = substr(s, pos, 1)
            if (ch == "\"") {
                readstring(s, pos)
                pos = nextpos
                continue
            }
            if (ch == "{" || ch == "[") { depth++ }
            else if (ch == "}" || ch == "]") {
                depth--
                if (depth == 0) { nextpos = pos + 1; return }
            }
            pos++
        }
        nextpos = pos
        return
    }
    # 数値、true、false、null
    while (pos <= length(s)) {
        ch = substr(s, pos, 1)
        if (ch == "," || ch == "}" || ch == "]" || isspace(ch)) { break }
        pos++
    }
    nextpos = pos
}

# pos の位置にあるオブジェクトから、欲しい4つのキーを取り出す。
function readobject(s, pos,   ch, key) {
    scope = ""; path = ""; sha = ""; ver = ""
    pos++            # 開きの { を飛ばす
    while (pos <= length(s)) {
        ch = substr(s, pos, 1)
        if (isspace(ch) || ch == ",") { pos++; continue }
        if (ch == "}") { nextpos = pos + 1; return }
        if (ch != "\"") { pos++; continue }

        readstring(s, pos)
        key = value
        pos = nextpos
        while (pos <= length(s) && substr(s, pos, 1) != ":") { pos++ }
        pos++
        while (pos <= length(s) && isspace(substr(s, pos, 1))) { pos++ }

        if (key == "scope" || key == "projectPath" ||
            key == "gitCommitSha" || key == "version") {
            if (substr(s, pos, 1) == "\"") {
                readstring(s, pos)
                if (key == "scope")             { scope = value }
                else if (key == "projectPath")  { path = value }
                else if (key == "gitCommitSha") { sha = value }
                else                            { ver = value }
                pos = nextpos
                continue
            }
        }
        skipvalue(s, pos)
        pos = nextpos
    }
    nextpos = pos
}

{ doc = doc $0 "\n" }

END {
    pos = index(doc, "\"" PLUGIN "\"")
    if (pos == 0) { exit }

    pos += length(PLUGIN) + 2
    while (pos <= length(doc) && substr(doc, pos, 1) != "[") { pos++ }
    pos++            # 開きの [ を飛ばす

    while (pos <= length(doc)) {
        ch = substr(doc, pos, 1)
        if (isspace(ch) || ch == ",") { pos++; continue }
        if (ch != "{") { break }      # ] に当たれば配列の終わり
        readobject(doc, pos)
        if (scope != "") {
            printf "%s\037%s\037%s\n", scope, path, (sha != "" ? sha : ver)
        }
        pos = nextpos
    }
}
