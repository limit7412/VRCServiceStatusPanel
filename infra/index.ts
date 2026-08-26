import * as pulumi from "@pulumi/pulumi";

import { createFunctions, Environment } from "./src/compute";
import { r2AccessKeyId, r2Endpoint, r2SecretAccessKey } from "./src/credentials";
import { cacheRuleset, publicBucket, stateBucket } from "./src/delivery";
import {
    alertWebhookUrl,
    boothProbeItemId,
    deliveryHost,
    githubDispatchToken,
    stack,
    youtubeProbeVideoId,
    ytdlpLayerVersion,
} from "./src/settings";

// 集約サーバー（Lambda）と配信経路（R2）をひとつの定義にまとめる。
//
// 両側を分けないのは、片側の値をもう片側が使うためである。R2 のバケット名も、
// トークンから導いた鍵も、そのまま Lambda の環境変数になる（仕様書 11.7）。
// 分けて書くと、その受け渡しを人が写すことになり、鍵を替えたときに写し忘れる。
//
// 中身は src/ にある。
//
//   settings.ts     スタックごとの設定
//   providers.ts    AWS プロバイダ（R2 バックエンドとの鍵の取り合いを解く）
//   delivery.ts     R2 のバケットと Cache Rules（仕様書 6）
//   credentials.ts  R2 の S3 互換トークンと、そこから導く鍵（仕様書 9）
//   functions.ts    関数の一覧。増やすときはここ
//   roles.ts        実行時のロール
//   compute.ts      Lambda、ロググループ、Scheduler（仕様書 5.1）
//
// このファイルは、それらを繋いで出力を並べるだけである。

// 仕様書 11.7 が挙げる環境変数。関数はどれも同じものを受け取る。
// main.cr は欠けていれば起動時に落とす。
const environment: Environment = {
    ENV: stack,
    R2_ENDPOINT: r2Endpoint,
    R2_PUBLIC_BUCKET: publicBucket.name,
    R2_STATE_BUCKET: stateBucket.name,
    R2_ACCESS_KEY_ID: r2AccessKeyId,
    R2_SECRET_ACCESS_KEY: r2SecretAccessKey,
    YOUTUBE_PROBE_VIDEO_ID: youtubeProbeVideoId,
    BOOTH_PROBE_ITEM_ID: boothProbeItemId,
    YTDLP_LAYER_VERSION: ytdlpLayerVersion,
    GITHUB_DISPATCH_TOKEN: githubDispatchToken,
    ALERT_WEBHOOK_URL: alertWebhookUrl,
};

const compute = createFunctions(environment);

// ---------------------------------------------------------------------------
// 出力
// ---------------------------------------------------------------------------

export const publicBucketOut = publicBucket.name;
export const stateBucketOut = stateBucket.name;
export const r2EndpointOut = r2Endpoint;
export const functionNames = pulumi.all(compute.functions.map((fn) => fn.name));
export const logGroupNames = pulumi.all(compute.logGroups.map((group) => group.name));
export const cacheRulesetId = cacheRuleset.id;
// カスタムドメインを手で繋ぐときの相手。
export const deliveryUrl = `https://${deliveryHost}/v1/status.json`;
