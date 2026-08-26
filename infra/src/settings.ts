import * as pulumi from "@pulumi/pulumi";

// スタックごとの設定をここで一度だけ読む。
// 値の意味と既定は Pulumi.yaml の config に書いてある。

const config = new pulumi.Config();

export const stack = pulumi.getStack();

/** リソース名の頭。同じアカウントに dev と prod を並べても衝突しない */
export const prefix = `vrc-service-status-panel-${stack}`;

// 明示したプロバイダはスタック設定の aws:region を自動では読まないため、
// ここで取り出しておく。既定は仕様書 5.1 の東京である。
export const awsRegion = new pulumi.Config("aws").get("region") ?? "ap-northeast-1";

export const cloudflareAccountId = config.require("cloudflareAccountId");
export const deliveryZoneId = config.require("deliveryZoneId");
export const deliveryHost = config.require("deliveryHost");

// 既定にスタック名を入れる。同じアカウントで dev と prod を並べたとき、
// 名前が同じだと後から作るほうが既存のバケットとぶつかり、通ってしまえば
// 配信も内部の記録も互いに上書きし合う。
// 名前を決めたい場合は publicBucket / stateBucket で明示する。
export const publicBucketName = config.get("publicBucket") || `status-public-${stack}`;
export const stateBucketName = config.get("stateBucket") || `status-state-${stack}`;
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
