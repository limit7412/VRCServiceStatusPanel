import * as pulumi from "@pulumi/pulumi";

// スタックごとの設定をここで一度だけ読む。
// 値の意味と既定は Pulumi.yaml の config に書いてある。

const config = new pulumi.Config();

/** スタック名の上限。下の checkStackName に導き方を書いてある */
const MAX_STACK_NAME = 16;

/**
 * スタック名を物理名に使えるか確かめる。
 *
 * Pulumi のスタック名はここより緩く、大文字も `_` も長い名前も通る。
 * そのまま物理名にすると、R2 は `_` を受け付けず、AWS と R2 は長さで弾く。
 * どちらも実際に作りに行くまで分からないので、ここで止める。
 *
 * 16 文字は `qazx7412-vrc-service-status-panel-<スタック名>-github-deploy` から
 * 逆算した値である。IAM ロール名の上限が 64 文字で、頭と接尾で 48 文字を使う。
 * このロールは infra/oidc/ が作るが、スタック名は両方で揃えるため上限も揃える。
 */
function checkStackName(name: string): string {
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/.test(name)) {
        throw new Error(
            `スタック名 "${name}" は物理名に使えない。` +
                "小文字、数字、ハイフンだけで、先頭と末尾は小文字か数字にする",
        );
    }
    if (name.length > MAX_STACK_NAME) {
        throw new Error(
            `スタック名 "${name}" が長い（${name.length} 文字）。` +
                `${MAX_STACK_NAME} 文字までにする`,
        );
    }
    return name;
}

export const stack = checkStackName(pulumi.getStack());

/**
 * リソース名の頭。
 *
 * 作成者の名前から始めるのは、同じ AWS / Cloudflare アカウントに置いた
 * 他のものと見分けるためである。スタック名まで含めるので、dev と prod を
 * 並べても衝突しない。デプロイロールの権限もこの頭で絞ってある。
 *
 * 長さの上限がいちばん厳しいのは Lambda の関数名で 64 文字である。
 * この頭とスタック名で 40 文字ほど使うため、handler 名に使えるのは
 * 20 文字ほどになる。
 */
export const prefix = `qazx7412-vrc-service-status-panel-${stack}`;

// 明示したプロバイダはスタック設定の aws:region を自動では読まないため、
// ここで取り出しておく。既定は仕様書 5.1 の東京である。
export const awsRegion = new pulumi.Config("aws").get("region") ?? "ap-northeast-1";

export const cloudflareAccountId = config.require("cloudflareAccountId");
export const deliveryZoneId = config.require("deliveryZoneId");
export const deliveryHost = config.require("deliveryHost");

// バケットも同じ頭で揃える。スタック名まで入れるのは、同じアカウントで
// dev と prod を並べたときに、名前が同じだと後から作るほうが既存のものと
// ぶつかり、通ってしまえば配信も内部の記録も互いに上書きし合うためである。
// 名前を決めたい場合は publicBucket / stateBucket で明示する。
export const publicBucketName = config.get("publicBucket") || `${prefix}-public`;
export const stateBucketName = config.get("stateBucket") || `${prefix}-state`;
export const bucketLocation = config.get("bucketLocation") ?? "apac";

export const ytdlpLayerArn = config.require("ytdlpLayerArn");
export const ytdlpLayerVersion = config.require("ytdlpLayerVersion");

export const youtubeProbeVideoId = config.require("youtubeProbeVideoId");
export const boothProbeItemId = config.require("boothProbeItemId");

export const githubDispatchToken = config.requireSecret("githubDispatchToken");
export const alertWebhookUrl = config.requireSecret("alertWebhookUrl");

// 実行時ロールに付ける上限。infra/oidc/ が作り、その出力をここへ入れる。
//
// 上限を決める場所を CI の届かないところへ置きたいので、本体では作らない。
// 同じプログラムに置くと、CI が自分を縛っている上限を書き換えられる。
//
// 手元からしかデプロイしないなら空でよい。CI からデプロイする場合は、
// デプロイロールが境界付きのロールしか作れないため、空だと CreateRole で止まる。
export const workloadBoundaryArn = config.get("workloadBoundaryArn") || undefined;
