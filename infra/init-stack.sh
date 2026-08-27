#!/usr/bin/env bash
# スタックを作り、仕様書 11.7 の値を入れる。
#
# CI から流すには Pulumi.<スタック名>.yaml が要る（#12）。まっさらなランナーには
# このファイルが無く、無いまま pulumi up を叩くと最初の config.require で止まる。
# Pulumi の設定は state ではなくこのファイルに入るためである。
#
# GitHub Actions からも流すなら、本体と infra/oidc/ を同じスタック名で作る。
# 二つがずれると、dev のデプロイロールでは prod を触れないまま CI が
# AccessDenied で止まる。手元からだけ流すなら infra/oidc/ は作らない。
#
# 二度目以降に流すと、いま入っている値を既定として見せる。Enter で通せば
# そのまま残る。空で答えても消えないので、消すときは pulumi config rm を使う。
#
# 使い方:
#   infra/init-stack.sh dev
#
# 値は一つずつ聞く。省略できるものは空のまま Enter で飛ばせる。
# 秘密の値は標準入力から渡すので、コマンドラインにも履歴にも残らない。
#
# 出来上がった二つの Pulumi.<スタック名>.yaml は commit する。--secret で入れた値は
# 暗号文として記録されるため平文では残らない。復号には PULUMI_CONFIG_PASSPHRASE が要る。

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)

stack="${1:-}"
case "$stack" in
    "" | -h | --help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        [ -n "$stack" ] && exit 0
        exit 2
        ;;
esac

# 名前の規則は infra/src/settings.ts と infra/oidc/index.ts に合わせる。
# ここで弾かないと、二つのスタックと十四の設定を作ったあと pulumi up が
# 名前の検証で必ず止まる。使えないスタックだけが残る。
MAX_STACK_NAME=16

if ! printf '%s' "$stack" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
    echo "スタック名 \"$stack\" は物理名に使えない。小文字、数字、ハイフンだけで、先頭と末尾は小文字か数字にする" >&2
    exit 2
fi

if [ "${#stack}" -gt "$MAX_STACK_NAME" ]; then
    echo "スタック名 \"$stack\" が長い（${#stack} 文字）。${MAX_STACK_NAME} 文字までにする" >&2
    exit 2
fi

if ! command -v pulumi > /dev/null 2>&1; then
    echo "pulumi が無い。https://www.pulumi.com/docs/install/ から入れる" >&2
    exit 1
fi

# パスフレーズは state と設定ファイルの中の secret を復号する鍵である。
# 失うと読めなくなるので、控えを残してもらう（仕様書 9.1）。
#
# 長さの下限を置くのは、設定ファイルを commit する先が public だからである（#24）。
# 暗号文が公開される以上、総当たりは誰でも好きなだけ試せる。Pulumi の鍵導出は
# PBKDF2-SHA256 を 100 万回まわすので一回の試行は重いが、人が思いついて
# 覚えられる範囲の文字列は、それでも辞書と規則の射程に入る。
#
# 文字種では見ない。規則を足すほど、生成した値が落ちて人が考えた値が通る、
# という逆転が起きる。ここで欲しいのは覚えずに生成させることなので、
# 覚えられない長さを下限にするだけでよい。
MIN_PASSPHRASE=32

# 鍵の材料になる文字列を、Pulumi と同じ形で取り出す。
#
# 環境変数はそのまま使われる（pkg/secrets/passphrase/manager.go の readPassphrase）。
# ファイルのほうは strings.TrimSpace を通してから使われる。$(cat) が落とすのは
# 末尾の改行だけなので、CRLF のファイルだと CR が残り、ここでの長さが Pulumi の
# 見る長さより一文字多くなる。下限をすり抜けられるので、前後の空白を自分で落とす。
phrase=""
if [ -n "${PULUMI_CONFIG_PASSPHRASE+set}" ]; then
    # 空で export されていても Pulumi はこちらを採る。os.LookupEnv は値ではなく
    # 設定の有無を見るためで、そのとき鍵は空文字から導かれる。値の有無で分けると、
    # ここではファイルを見て通し、Pulumi は空文字で暗号化する、という食い違いになる。
    # 空なら下の長さの検査が 0 文字として弾く。
    phrase="$PULUMI_CONFIG_PASSPHRASE"
elif [ -n "${PULUMI_CONFIG_PASSPHRASE_FILE:-}" ]; then
    # 相対パスは絶対パスへ直して環境変数へ書き戻す。
    #
    # pulumi -C は「そのディレクトリで起動したかのように」振る舞うので、相対の
    # ままだと Pulumi は infra/ や infra/oidc/ から解決する。ここで読むファイルと
    # 食い違い、無ければスタックの作成が落ち、別の短いファイルがあれば検査した値と
    # 違う鍵で暗号化される。Pulumi CLI 3.259.0 で、-C の先から解決することを確かめた。
    case "$PULUMI_CONFIG_PASSPHRASE_FILE" in
        /*) ;;
        *) PULUMI_CONFIG_PASSPHRASE_FILE="$PWD/$PULUMI_CONFIG_PASSPHRASE_FILE" ;;
    esac
    export PULUMI_CONFIG_PASSPHRASE_FILE

    if [ ! -r "$PULUMI_CONFIG_PASSPHRASE_FILE" ]; then
        echo "PULUMI_CONFIG_PASSPHRASE_FILE が読めない: $PULUMI_CONFIG_PASSPHRASE_FILE" >&2
        exit 1
    fi
    phrase=$(cat "$PULUMI_CONFIG_PASSPHRASE_FILE")
    phrase="${phrase#"${phrase%%[![:space:]]*}"}"
    phrase="${phrase%"${phrase##*[![:space:]]}"}"
else
    echo "PULUMI_CONFIG_PASSPHRASE が要る。これを失うと secret を読めなくなるので、控えを残すこと" >&2
    exit 1
fi

if [ "${#phrase}" -lt "$MIN_PASSPHRASE" ]; then
    echo "PULUMI_CONFIG_PASSPHRASE が短い（${#phrase} 文字）。${MIN_PASSPHRASE} 文字以上にする" >&2
    echo "  設定ファイルは commit され、このリポジトリは public である（#24）" >&2
    echo "  覚えずに済ませる。次のように作って、パスワードマネージャへ入れる" >&2
    echo "    openssl rand -base64 32" >&2
    echo >&2
    echo "  既にこのパスフレーズでスタックを作ってあるなら、先に入れ替える。" >&2
    echo "  古いほうを PULUMI_CONFIG_PASSPHRASE に入れたまま次を実行すると、" >&2
    echo "  新しいパスフレーズを聞かれ、設定と state が入れ替わったもので暗号化し直される。" >&2
    echo "    pulumi -C \"$here\" stack change-secrets-provider passphrase --stack $stack" >&2
    echo "  GitHub Actions からも流しているなら、infra/oidc/ 側も同じ古いパスフレーズで" >&2
    echo "  作ってあるので、環境変数を切り替える前にこちらも入れ替える。忘れると、" >&2
    echo "  次に infra/oidc/ を流したときに state を復号できない。" >&2
    echo "    pulumi -C \"$here/oidc\" stack change-secrets-provider passphrase --stack $stack" >&2
    echo "  そのあと新しいほうを PULUMI_CONFIG_PASSPHRASE に入れて、ここへ戻る。" >&2
    echo >&2
    echo "  古い設定ファイルを commit してあるなら、入れ替えだけでは足りない。" >&2
    echo "  古い暗号文は履歴に残り、弱いパスフレーズごと総当たりの的になる。" >&2
    echo "  そこに入っていた secret は作り直す（alertWebhookUrl、設定へ入れていたなら" >&2
    echo "  Cloudflare のトークンも）。" >&2
    exit 1
fi

# 入力が尽きたら止める。省略ではなく中断だからである。
# 省略できない値を聞いている途中で Ctrl-D を押されたときに、
# 同じ警告を出し続ける無限ループにならないようにする。
# この実行で新しく作ったスタック。中断したときの案内に使う。
# 元からあったスタックを「作りかけ」として案内すると、
# 案内どおりに消したときに以前からある設定ごと消えてしまう。
created_main=no
created_oidc=no


abort_on_eof() {
    printf '\n' >&2
    echo "入力が尽きたので中断する。" >&2

    if [ "$created_main" = no ] && [ "$created_oidc" = no ]; then
        echo "この実行で作ったスタックは無いので、消すものも無い" >&2
        exit 1
    fi

    echo "この実行で作ったスタックを消すなら、次を実行する" >&2
    [ "$created_main" = no ] || echo "  pulumi -C \"$here\" stack rm $stack" >&2
    [ "$created_oidc" = no ] || echo "  pulumi -C \"$here/oidc\" stack rm $stack" >&2
    exit 1
}

# 一問だけ聞く。答えは ANSWER に入れる。既定があれば、空の答えはそれで埋める。
# EOF なら 1 を返す。呼び出し側は abort_on_eof で止める。
#
# 秘密の値は端末へ出さない。履歴に残らなくても、打っている最中の画面と
# セッションの録画には残るためである。
ask() {
    local label="$1" default="${2:-}" hidden="${3:-}"

    ANSWER=""

    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi

    if [ -n "$hidden" ]; then
        # -s は改行を出さないので、こちらで出す
        read -rs ANSWER || return 1
        printf '\n' >&2
    else
        read -r ANSWER || return 1
    fi

    [ -n "$ANSWER" ] || ANSWER="$default"
    return 0
}

# いま設定に入っている値。無ければ空を返す。
#
# 二度目以降の実行で、入っている値を既定として見せるために使う。
# 見せずに聞くと、Enter で通したときに何が残ったのか分からない。
# 空で答えても消えはしない。消したいときは pulumi config rm を使う。
current_config() {
    local dir="$1" key="$2"

    pulumi -C "$dir" config get --stack "$stack" "$key" 2> /dev/null || true
}

# 省略できない値。空で返ってきたら聞き直す。
set_required() {
    local dir="$1" key="$2" label="$3" default="${4:-}" existing=""

    existing=$(current_config "$dir" "$key")
    [ -z "$existing" ] || default="$existing"

    while :; do
        ask "$label" "$default" || abort_on_eof
        [ -n "$ANSWER" ] && break
        echo "  ここは省略できない" >&2
    done

    pulumi -C "$dir" config set --stack "$stack" "$key" "$ANSWER"
}

# 省略できる値。空なら設定へ書かない。
set_optional() {
    local dir="$1" key="$2" label="$3" default="${4:-}" existing=""

    existing=$(current_config "$dir" "$key")
    [ -z "$existing" ] || default="$existing"

    ask "$label" "$default" || abort_on_eof
    if [ -z "$ANSWER" ]; then
        return 0
    fi

    pulumi -C "$dir" config set --stack "$stack" "$key" "$ANSWER"
}

# 設定にその値が入っているか。中身は取り出さない。
#
# 秘密の値について「入っているか」だけを知りたいときに使う。
# current_config は復号した平文を返すので、こちらでは呼ばない。
has_config() {
    local dir="$1" key="$2"

    pulumi -C "$dir" config get --stack "$stack" "$key" > /dev/null 2>&1
}

# そのプロジェクトにこのスタックがあるか。
#
# stack select は見つからなければ 6 を返すが、見つかると選び直してしまう。
# ここは既定値を決めるために覗くだけなので、読むだけの stack ls を使う。
#
# 一覧は変数へ受けてから読む。pulumi へ直に繋ぐと、grep -q が最初の一致で
# 抜けたときに SIGPIPE で 141 になり、pipefail がそれを拾ってしまう。
# 整形に頼らない形で照合するのは、詰めて出力されても通るようにするためである。
stack_exists() {
    local dir="$1" listed=""

    listed=$(pulumi -C "$dir" stack ls --json 2> /dev/null) || return 1
    grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"$stack\"" <<< "$listed"
}

# 秘密の値。打っている最中も画面に出さず、標準入力から渡して暗号文として記録する。
#
# 二度目以降は Enter で今の値のままにできる。既定として見せることはしない。
# 見せれば画面に出てしまい、隠して聞いた意味が無くなる。
set_secret() {
    local dir="$1" key="$2" label="$3" keep=""

    if has_config "$dir" "$key"; then
        keep="$label（Enter で今の値のまま）"
    fi

    while :; do
        ask "${keep:-$label}" "" hidden || abort_on_eof
        [ -n "$ANSWER" ] && break
        [ -z "$keep" ] || return 0
        echo "  ここは省略できない" >&2
    done

    printf '%s' "$ANSWER" | pulumi -C "$dir" config set --stack "$stack" --secret "$key"
}

# 以前の init-stack.sh が入れていた値を落とす。
#
# 質問から外しただけでは Pulumi.<スタック名>.yaml に残る。secret 指定の値なら
# 暗号文で残り、その設定ファイルは commit する。パスフレーズを持つ相手は
# 復号できるので、消したつもりの資格情報が commit 済みの履歴に残り続ける。
drop_config() {
    local dir="$1" key="$2" why="$3"

    has_config "$dir" "$key" || return 0

    pulumi -C "$dir" config rm --stack "$stack" "$key" > /dev/null
    echo "  $key を消した。$why"
}

# 名前を変えた設定を引き継ぐ。
#
# 新しい側がまだ空のときだけ写す。既に入っていれば、そちらが新しいので触らない。
# 写し終えたら古い側を落とす。残しておくと、読む者のいないキーが
# commit 済みの設定ファイルに溜まる。
#
# secret 指定の値には使わない。current_config は復号した平文を返すので、
# そのまま config set へ渡すと暗号文だったものが平文で書き直される。
rename_config() {
    local dir="$1" old="$2" new="$3"

    has_config "$dir" "$old" || return 0

    if ! has_config "$dir" "$new"; then
        pulumi -C "$dir" config set --stack "$stack" "$new" "$(current_config "$dir" "$old")"
        echo "  $old を $new へ引き継いだ"
    fi

    pulumi -C "$dir" config rm --stack "$stack" "$old" > /dev/null
}

# スタックを選ぶ。無ければ作る。
# 新しく作ったときだけ 0 を返す。元からあった場合は 1 を返し、
# 中断時の削除案内から外す。
create_stack() {
    local dir="$1"

    if pulumi -C "$dir" stack select "$stack" > /dev/null 2>&1; then
        return 1
    fi

    # 終了状態を自分で見る。この関数は `create_stack ... && created=yes` の形で
    # 呼ばれるため、中では errexit が効かない。任せると、置き場所へ繋がらない
    # ときや認証に失敗したときでも return 0 まで進み、作ったことにして
    # 設定を書き始めてしまう。
    if ! pulumi -C "$dir" stack select --create "$stack" --secrets-provider passphrase > /dev/null; then
        echo "スタック $stack を作れなかった（$dir）" >&2
        exit 1
    fi

    return 0
}

# infra/oidc/ は CI の入口である。手元からだけ流すなら要らない。
# 作らせると、使わない OIDC プロバイダと IAM ロールを作る権限まで要ることになる。
# 本体の workloadBoundaryArn は省略できるので、無くても手元からは流せる。
# 既定は、いま在るスタックから決める。
# 手元からだけとして作ったスタックへ二度目を流したとき、Enter で通しただけで
# CI 利用へ切り替わり、要らない OIDC のスタックができてしまうのを避ける。
#
# 設定キーの有無では見ない。スタックを作った直後から最初の config set までの
# 間に中断すると、スタックは在るのに設定はまだ無い。そこで再開すると既定が
# y へ戻り、続きを流しただけのつもりで OIDC まで作ることになる。
ci_default=y
if stack_exists "$here" && ! stack_exists "$here/oidc"; then
    ci_default=n
fi

use_ci=""
while [ -z "$use_ci" ]; do
    ask "GitHub Actions からもデプロイするか（y/n）" "$ci_default" || abort_on_eof

    # 打ち間違いを no として飲み込まない。飲み込むと、CI を使うつもりでも
    # スタックも質問も案内も黙って省かれる。
    # ${ANSWER,,} は Bash 4 からで、macOS 標準の 3.2 では bad substitution になる。
    # case のパターンで大文字小文字を吸収する。
    case "$ANSWER" in
        [Yy] | [Yy][Ee][Ss]) use_ci=yes ;;
        [Nn] | [Nn][Oo]) use_ci=no ;;
        *) echo "  y か n で答える" >&2 ;;
    esac
done

echo
echo "=== $stack を作る ==="
create_stack "$here" && created_main=yes

if [ "$use_ci" = yes ]; then
    create_stack "$here/oidc" && created_oidc=yes
fi

# 使わなくなった設定を落とす。
#
# 質問から外すだけでは、以前の init-stack.sh で作ったスタックに残り続ける。
# githubDispatchToken はリポジトリへの書き込み権限を持つトークンで、
# 暗号文とはいえ commit 済みの設定ファイルに入ったままになる。
drop_config "$here" githubDispatchToken "GitHub 側でこのトークンを失効させること。commit 済みの履歴からは消えない"
drop_config "$here" ytdlpLayerArn "Layer は pulumi up が作るので、ARN を設定に持たない"
drop_config "$here" cloudflare:apiToken "CLOUDFLARE_API_TOKEN で渡す。commit 済みの履歴に暗号文が残っているなら、トークンを作り直すこと"
rename_config "$here" ytdlpLayerVersion ytdlpVersion

# 二度目の実行で Enter を押したときに、既定のリージョンで上書きしない。
# 別のリージョンで作ってあると、AWS のリソースが置き換わり、
# 発行済みの Layer とも食い違う。
region_default=$(current_config "$here" aws:region)
[ -n "$region_default" ] || region_default="ap-northeast-1"

ask "AWS のリージョン（仕様書 5.1）" "$region_default" || abort_on_eof
pulumi -C "$here" config set --stack "$stack" aws:region "$ANSWER"
[ "$use_ci" = no ] || pulumi -C "$here/oidc" config set --stack "$stack" aws:region "$ANSWER"

echo
echo "--- Cloudflare（仕様書 6） ---"
# API トークンはここでは聞かない。CLOUDFLARE_API_TOKEN で渡す（#24）。
#
# 設定へ入れると commit されるファイルに暗号文が載る。プロバイダは環境変数からも
# 読むので、入れる意味が無い。CI は元からこの環境変数で渡している。
set_required "$here" cloudflareAccountId "アカウント ID"
set_required "$here" deliveryZoneId "配信ドメインのゾーン ID"
set_required "$here" deliveryHost "配信ホスト名（例 status.example.com）"
set_optional "$here" bucketLocation "バケットの場所" "apac"
set_optional "$here" publicBucket "配信バケット名（既定 qazx7412-vrc-service-status-panel-$stack-public）"
set_optional "$here" stateBucket "内部バケット名（既定 qazx7412-vrc-service-status-panel-$stack-state）"

echo
echo "--- 合成監視の対象（仕様書 3.3） ---"
set_required "$here" youtubeProbeVideoId "YouTube の固定動画 ID"
set_required "$here" boothProbeItemId "BOOTH の商品 ID"

echo
echo "--- 集約サーバー（仕様書 7.3、11.7） ---"
set_required "$here" ytdlpVersion "Layer に載せる yt-dlp の版（VRChat の /config の youtubedl_version に合わせる）"
set_secret "$here" alertWebhookUrl "失敗時のアラート送信先 URL"

if [ "$use_ci" = yes ]; then
    echo
    echo "--- GitHub Actions からの入口（仕様書 9.1） ---"
    set_required "$here/oidc" githubRepository "デプロイを許すリポジトリ" "limit7412/VRCServiceStatusPanel"
    set_optional "$here/oidc" githubOidcProviderArn "既にある OIDC プロバイダの ARN（無ければ空のまま）"
fi

# 案内は絶対パスで出す。README の手順は infra/ から実行するので、
# infra/oidc のような相対パスを出すと、そこからは infra/infra/oidc を指してしまう。
echo
echo "=== ここまでで出来たもの ==="
echo "  $here/Pulumi.$stack.yaml"
[ "$use_ci" = no ] || echo "  $here/oidc/Pulumi.$stack.yaml"
echo
echo "次にやること"

# Layer は pulumi up が作るので、初回と二度目で案内は変わらない。
#
# Cloudflare のトークンは設定に入らないので、流す前に環境変数へ入れてもらう（#24）。
deploy_line="       printf 'CLOUDFLARE_API_TOKEN: '; read -rs cloudflare_token && echo
       CLOUDFLARE_API_TOKEN=\"\$cloudflare_token\" \"$here/deploy.sh\""
deploy_label="本体を流す（Layer もここで作られる）"

if [ "$use_ci" = no ]; then
    echo "  1. 出来た Pulumi.$stack.yaml を commit する（#12）"
    echo "  2. $deploy_label"
    echo "$deploy_line"
else
    echo "  1. 入口と権限境界を作る"
    echo "       npm ci --prefix \"$here/oidc\""
    echo "       pulumi -C \"$here/oidc\" up"
    echo "     infra/oidc/ は package-lock を別に持つ。infra/ の npm ci では入らない"
    echo "  2. その workloadBoundaryArn を本体へ入れる"
    echo "       pulumi -C \"$here\" config set --stack $stack workloadBoundaryArn \\"
    echo "         \"\$(pulumi -C \"$here/oidc\" stack output workloadBoundaryArn)\""
    echo "  3. 二つの Pulumi.$stack.yaml を commit する（#12）"
    echo "     commit は 2 のあとにする。境界を入れる前の設定を commit すると、"
    echo "     CI はそれを checkout して境界の付いていないロールを作ろうとし、"
    echo "     DenyBoundaryRemoval で止まる"
    echo "  4. $deploy_label"
    echo "$deploy_line"
    echo "  5. 次の五つを GitHub の Secrets へ登録する"
    echo "       AWS_DEPLOY_ROLE_ARN"
    echo "         pulumi -C \"$here/oidc\" stack output githubDeployRoleArn"
    echo "       PULUMI_CONFIG_PASSPHRASE        いま使ったもの"
    echo "       PULUMI_STATE_ACCESS_KEY_ID      状態の置き場所（R2）の鍵"
    echo "       PULUMI_STATE_SECRET_ACCESS_KEY  同上"
    echo "       CLOUDFLARE_API_TOKEN            Cloudflare の API トークン"
    echo "     どれが何に使われるかは README の「ワークフローでの受け取り」にある"
fi
