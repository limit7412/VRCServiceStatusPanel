#!/usr/bin/env bash
# スタックを作り、仕様書 11.7 の値を入れる。
#
# CI から流すには Pulumi.<スタック名>.yaml が要る（#12）。まっさらなランナーには
# このファイルが無く、無いまま pulumi up を叩くと最初の config.require で止まる。
# Pulumi の設定は state ではなくこのファイルに入るためである。
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
# 出来上がった Pulumi.<スタック名>.yaml は commit する。--secret で入れた値は
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

# 名前の規則は infra/src/settings.ts に合わせる。
# ここで弾かないと、スタックと十四の設定を作ったあと pulumi up が
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

# パスフレーズは state の中の secret を復号する鍵である。
# 失うと state を読めなくなるので、控えを残してもらう（仕様書 9.1）。
if [ -z "${PULUMI_CONFIG_PASSPHRASE:-}" ] && [ -z "${PULUMI_CONFIG_PASSPHRASE_FILE:-}" ]; then
    echo "PULUMI_CONFIG_PASSPHRASE が要る。これを失うと state の secret を読めなくなるので、控えを残すこと" >&2
    exit 1
fi

# 入力が尽きたら止める。省略ではなく中断だからである。
# 省略できない値を聞いている途中で Ctrl-D を押されたときに、
# 同じ警告を出し続ける無限ループにならないようにする。
# この実行で新しく作ったスタック。中断したときの案内に使う。
# 元からあったスタックを「作りかけ」として案内すると、
# 案内どおりに消したときに以前からある設定ごと消えてしまう。
created_main=no


abort_on_eof() {
    printf '\n' >&2
    echo "入力が尽きたので中断する。" >&2

    if [ "$created_main" = no ]; then
        echo "この実行で作ったスタックは無いので、消すものも無い" >&2
        exit 1
    fi

    echo "この実行で作ったスタックを消すなら、次を実行する" >&2
    echo "  pulumi -C \"$here\" stack rm $stack" >&2
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

# AWS の資格情報を移して aws を呼ぶ。出力は標準出力へ、雑音は捨てる。
#
# ここまでで AWS_* に入っているのは状態の置き場所（R2）の鍵である。
# そのままでは AWS へ通らないので、deploy.sh と同じく DEPLOY_AWS_* を移す。
# 移すのは元の変数がある場合だけで、R2 をバックエンドにしていない環境では
# もとの AWS_* がそのまま使われる。
#
# aws が無ければ 1 を返す。呼び出し側はどちらも「既定が無い」として扱う。
aws_deploy() {
    command -v aws > /dev/null 2>&1 || return 1

    env \
        ${DEPLOY_AWS_ACCESS_KEY_ID:+AWS_ACCESS_KEY_ID="$DEPLOY_AWS_ACCESS_KEY_ID"} \
        ${DEPLOY_AWS_SECRET_ACCESS_KEY:+AWS_SECRET_ACCESS_KEY="$DEPLOY_AWS_SECRET_ACCESS_KEY"} \
        ${DEPLOY_AWS_SESSION_TOKEN:+AWS_SESSION_TOKEN="$DEPLOY_AWS_SESSION_TOKEN"} \
        aws "$@" 2> /dev/null
}

# 設定にその値が入っているか。中身は取り出さない。
#
# 秘密の値について「入っているか」だけを知りたいときに使う。
# current_config は復号した平文を返すので、こちらでは呼ばない。
has_config() {
    local dir="$1" key="$2"

    pulumi -C "$dir" config get --stack "$stack" "$key" > /dev/null 2>&1
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

echo
echo "=== $stack を作る ==="
create_stack "$here" && created_main=yes

# 使わなくなった設定を落とす。
#
# 質問から外すだけでは、以前の init-stack.sh で作ったスタックに残り続ける。
# githubDispatchToken はリポジトリへの書き込み権限を持つトークンで、
# 暗号文とはいえ commit 済みの設定ファイルに入ったままになる。
drop_config "$here" githubDispatchToken "GitHub 側でこのトークンを失効させること。commit 済みの履歴からは消えない"
drop_config "$here" ytdlpLayerArn "Layer は pulumi up が作るので、ARN を設定に持たない"
rename_config "$here" ytdlpLayerVersion ytdlpVersion

# 二度目の実行で Enter を押したときに、既定のリージョンで上書きしない。
# 別のリージョンで作ってあると、AWS のリソースが置き換わり、
# 発行済みの Layer とも食い違う。
region_default=$(current_config "$here" aws:region)
[ -n "$region_default" ] || region_default="ap-northeast-1"

ask "AWS のリージョン（仕様書 5.1）" "$region_default" || abort_on_eof
pulumi -C "$here" config set --stack "$stack" aws:region "$ANSWER"

echo
echo "--- Cloudflare（仕様書 6） ---"
set_secret "$here" cloudflare:apiToken "API トークン（要る権限は README の「Cloudflare の API トークン」）"
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

# CI から流すかどうかは、権限境界の ARN を入れるかどうかで決まる。
# 入れれば実行時ロールに境界が付き、デプロイロールがそのロールを作れる。
# 入れなければ手元からしか流せない。
#
# 境界は Pulumi ではなく AWS CLI で作ってある（docs/aws-oidc.md）。
# 既定はいま繋がっているアカウントから組み立てる。ARN にはアカウント ID が
# 入るので、public のこのリポジトリには書かない。
#
# 実在を確かめてからでないと既定にしない。ask は空の答えを既定で埋めるので、
# 無いものを既定に出すと、Enter で通しただけで存在しない境界を指すことになる。
# fork 先のように境界をまだ作っていないアカウントでは、そのまま流すと
# 最初の CreateRole が落ちる。無ければ既定を空にして、Enter で飛ばせるようにする。
#
# aws が無いときも、資格情報が通らないときも、同じく既定が空になるだけである。
# その場合は ARN を手で貼る。
boundary_default=""
boundary_name=qazx7412-vrc-service-status-panel-workload-boundary
account=$(aws_deploy sts get-caller-identity --query Account --output text || true)
if [ -n "$account" ] && [ "$account" != "None" ]; then
    candidate="arn:aws:iam::$account:policy/$boundary_name"
    if aws_deploy iam get-policy --policy-arn "$candidate" > /dev/null; then
        boundary_default="$candidate"
    fi
fi

echo
echo "--- GitHub Actions からの入口（仕様書 9.1） ---"
set_optional "$here" workloadBoundaryArn \
    "実行時ロールの権限境界の ARN（CI から流さないなら空のまま）" "$boundary_default"

# 案内は絶対パスで出す。README の手順は infra/ から実行するので、
# 相対パスを出すと、そこからは infra/infra を指してしまう。
echo
echo "=== ここまでで出来たもの ==="
echo "  $here/Pulumi.$stack.yaml"
echo
echo "次にやること"

# Layer は pulumi up が作るので、初回と二度目で案内は変わらない。
deploy_line="       \"$here/deploy.sh\""
deploy_label="本体を流す（Layer もここで作られる）"

echo "  1. 出来た Pulumi.$stack.yaml を commit する（#12）"
echo "  2. $deploy_label"
echo "$deploy_line"

# 境界を入れていないスタックは手元専用である。CI 向けの案内は出さない。
if has_config "$here" workloadBoundaryArn; then
    echo "  3. 次の五つが GitHub の Secrets にあるか確かめる"
    echo "       AWS_DEPLOY_ROLE_ARN             デプロイロールの ARN（docs/aws-oidc.md）"
    echo "       PULUMI_CONFIG_PASSPHRASE        いま使ったもの"
    echo "       PULUMI_STATE_ACCESS_KEY_ID      状態の置き場所（R2）の鍵"
    echo "       PULUMI_STATE_SECRET_ACCESS_KEY  同上"
    echo "       CLOUDFLARE_API_TOKEN            Cloudflare の API トークン"
    echo "     どれが何に使われるかは README の「ワークフローでの受け取り」にある"
fi
