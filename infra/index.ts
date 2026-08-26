import * as crypto from "crypto";
import * as aws from "@pulumi/aws";
import * as cloudflare from "@pulumi/cloudflare";
import * as pulumi from "@pulumi/pulumi";

// 集約サーバー（Lambda）と配信経路（R2）をひとつの定義にまとめる。
//
// 両側を分けないのは、片側の値をもう片側が使うためである。R2 のバケット名も、
// トークンから導いた鍵も、そのまま Lambda の環境変数になる（仕様書 11.7）。
// 分けて書くと、その受け渡しを人が写すことになり、鍵を替えたときに写し忘れる。

const config = new pulumi.Config();
const stack = pulumi.getStack();
const prefix = `vrc-service-status-panel-${stack}`;

const cloudflareAccountId = config.require("cloudflareAccountId");
const deliveryZoneId = config.require("deliveryZoneId");
const deliveryHost = config.require("deliveryHost");
const publicBucketName = config.get("publicBucket") ?? "status-public";
const stateBucketName = config.get("stateBucket") ?? "status-state";
const bucketLocation = config.get("bucketLocation") ?? "apac";
const ytdlpLayerArn = config.require("ytdlpLayerArn");
const ytdlpLayerVersion = config.require("ytdlpLayerVersion");

// ---------------------------------------------------------------------------
// 配信と内部の保存先（仕様書 6）
// ---------------------------------------------------------------------------

// バケットを消すと配信も履歴も失う。protect を付けて、
// destroy や置き換えを伴う変更が誤って通らないようにする。
const publicBucket = new cloudflare.R2Bucket(
    "public",
    {
        accountId: cloudflareAccountId,
        name: publicBucketName,
        location: bucketLocation,
    },
    { protect: true },
);

const stateBucket = new cloudflare.R2Bucket(
    "state",
    {
        accountId: cloudflareAccountId,
        name: stateBucketName,
        location: bucketLocation,
    },
    { protect: true },
);

// 配信 JSON は .json なので、既定ではキャッシュの対象にならない（仕様書 6）。
// Cache Rules で /v1/ 以下を対象に入れる。
//
// edgeTtl は respect_origin を使う。オブジェクトの Cache-Control に従わせる
// ためで、仕様書 6 の「オブジェクトの Cache-Control に従い 30 秒」がこれにあたる。
// override_origin で 30 秒を書くことはできない。Edge Cache TTL の下限が
// Free で 2 時間、Pro で 1 時間あり、Business 以上でないと 30 秒を指定できない。
const cacheRuleset = new cloudflare.Ruleset("delivery-cache", {
    zoneId: deliveryZoneId,
    name: "VRCServiceStatusPanel の配信",
    description: "配信 JSON をキャッシュの対象に入れる",
    kind: "zone",
    phase: "http_request_cache_settings",
    rules: [
        {
            ref: "cache_status_feed",
            description: "v1 以下をキャッシュし、TTL はオブジェクトに従う",
            expression: `(http.host eq "${deliveryHost}" and starts_with(http.request.uri.path, "/v1/"))`,
            action: "set_cache_settings",
            actionParameters: {
                cache: true,
                edgeTtl: { mode: "respect_origin" },
                browserTtl: { mode: "respect_origin" },
            },
        },
    ],
});

// カスタムドメインはここでは作らない。
//
// cloudflare_r2_custom_domain には、作成の約一分後に enabled が false へ戻る
// 不具合がある（cloudflare/terraform-provider-cloudflare#6578）。Pulumi の
// Cloudflare プロバイダは同じ Terraform プロバイダを包んだものなので、
// 同じ挙動になる。配信そのものが止まる箇所であり、載せる利より害が大きい。
//
// 当面はダッシュボードから publicBucketName のバケットへ deliveryHost を
// 繋ぐ。手順は infra/README.md に書いてある。
// 不具合が直れば、ここに R2CustomDomain を足すだけで済む。

// ---------------------------------------------------------------------------
// R2 の鍵（仕様書 9）
// ---------------------------------------------------------------------------

// R2 のトークンで選べるのは Admin Read & Write、Admin Read only、
// Object Read & Write、Object Read only の四つで、書き込みのみの段階は無い。
// S3 互換 API から使えるのは Object 系だけなので、書ける最小の権限がこれになる。
//
// 選んだ段階は対象のバケット全体へ一律に効くため、一組の鍵で公開バケットだけを
// 別扱いにはできない。分けたい場合はトークンを二つに割ることになる。
// この差は仕様書 9 の記述と食い違っており、#9 で扱う。
const R2_OBJECT_READ_WRITE = "2efd5506f9c8494dacb1fa10a3e7d5b6";

// バケットは特定の管轄に作っていないので default になる。
const bucketResource = (name: string) =>
    `com.cloudflare.edge.r2.bucket.${cloudflareAccountId}_default_${name}`;

const r2Token = new cloudflare.AccountToken("r2", {
    accountId: cloudflareAccountId,
    name: `${prefix}-r2`,
    policies: [
        {
            effect: "allow",
            permissionGroups: [{ id: R2_OBJECT_READ_WRITE }],
            resources: pulumi
                .all([publicBucket.name, stateBucket.name])
                .apply(([pub, st]) =>
                    JSON.stringify({
                        [bucketResource(pub)]: "*",
                        [bucketResource(st)]: "*",
                    }),
                ),
        },
    ],
});

// S3 互換 API の資格情報はトークンから導く。
// Access Key ID はトークンの id、Secret Access Key はトークンの値の SHA-256 である。
const r2AccessKeyId = r2Token.id;
const r2SecretAccessKey = pulumi.secret(
    r2Token.value.apply((value) => crypto.createHash("sha256").update(value).digest("hex")),
);
const r2Endpoint = `https://${cloudflareAccountId}.r2.cloudflarestorage.com`;

// ---------------------------------------------------------------------------
// 集約サーバー（仕様書 5.1）
// ---------------------------------------------------------------------------

const lambdaRole = new aws.iam.Role("lambda", {
    name: `${prefix}-lambda`,
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [
            {
                Effect: "Allow",
                Principal: { Service: "lambda.amazonaws.com" },
                Action: "sts:AssumeRole",
            },
        ],
    }),
});

// ロググループを先に作る。Lambda に任せると保持期間が無期限になり、
// 60 秒ごとの記録が消えずに溜まり続ける。
const logGroup = new aws.cloudwatch.LogGroup("lambda", {
    name: `/aws/lambda/${prefix}-refresh`,
    retentionInDays: 14,
});

const lambdaLogPolicy = new aws.iam.RolePolicy("lambda-logs", {
    name: "logs",
    role: lambdaRole.id,
    policy: logGroup.arn.apply((arn) =>
        JSON.stringify({
            Version: "2012-10-17",
            Statement: [
                {
                    Effect: "Allow",
                    Action: ["logs:CreateLogStream", "logs:PutLogEvents"],
                    Resource: `${arn}:*`,
                },
            ],
        }),
    ),
});

// backend/build.sh が作った zip をそのまま渡す。
//
// ディレクトリから AssetArchive を組むと実行権限が落ち、provided ランタイムが
// bootstrap を起動できない。出来上がった zip を渡せば、モードは zip の中の
// 記録がそのまま使われる。
const refresh = new aws.lambda.Function(
    "refresh",
    {
        name: `${prefix}-refresh`,
        role: lambdaRole.arn,
        code: new pulumi.asset.FileArchive("../backend/bootstrap.zip"),
        // provided ランタイムが動かすのは zip 直下の bootstrap で、
        // この文字列は _HANDLER として渡るだけである。
        handler: "bootstrap",
        runtime: "provided.al2023",
        architectures: ["arm64"],
        // yt-dlp を動かす余裕を見込む（仕様書 5.1）。
        memorySize: 512,
        timeout: 40,
        layers: [ytdlpLayerArn],
        loggingConfig: {
            logFormat: "Text",
            logGroup: logGroup.name,
        },
        environment: {
            // 仕様書 11.7 が挙げる環境変数。main.cr は欠けていれば起動時に落とす。
            variables: {
                ENV: stack,
                R2_ENDPOINT: r2Endpoint,
                R2_PUBLIC_BUCKET: publicBucket.name,
                R2_STATE_BUCKET: stateBucket.name,
                R2_ACCESS_KEY_ID: r2AccessKeyId,
                R2_SECRET_ACCESS_KEY: r2SecretAccessKey,
                YOUTUBE_PROBE_VIDEO_ID: config.require("youtubeProbeVideoId"),
                BOOTH_PROBE_ITEM_ID: config.require("boothProbeItemId"),
                YTDLP_LAYER_VERSION: ytdlpLayerVersion,
                GITHUB_DISPATCH_TOKEN: config.requireSecret("githubDispatchToken"),
                ALERT_WEBHOOK_URL: config.requireSecret("alertWebhookUrl"),
            },
        },
    },
    { dependsOn: [lambdaLogPolicy] },
);

// ---------------------------------------------------------------------------
// 起動（仕様書 5.1）
// ---------------------------------------------------------------------------

// EventBridge Scheduler は自前のロールで対象を呼ぶ。
// EventBridge のルールと違い、関数側のリソースポリシーでは足りない。
const schedulerRole = new aws.iam.Role("scheduler", {
    name: `${prefix}-scheduler`,
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [
            {
                Effect: "Allow",
                Principal: { Service: "scheduler.amazonaws.com" },
                Action: "sts:AssumeRole",
            },
        ],
    }),
});

new aws.iam.RolePolicy("scheduler-invoke", {
    name: "invoke",
    role: schedulerRole.id,
    policy: refresh.arn.apply((arn) =>
        JSON.stringify({
            Version: "2012-10-17",
            Statement: [
                {
                    Effect: "Allow",
                    Action: "lambda:InvokeFunction",
                    Resource: arn,
                },
            ],
        }),
    ),
});

// 60 秒間隔で起動する（仕様書 5.1）。
// EventBridge Scheduler を使うのは、最小間隔が 1 分で仕様と一致するためである。
new aws.scheduler.Schedule("refresh", {
    name: `${prefix}-refresh`,
    scheduleExpression: "rate(1 minute)",
    // 揺らぎを入れない。60 秒ごとに揃えて動かしたい。
    flexibleTimeWindow: { mode: "OFF" },
    target: {
        arn: refresh.arn,
        roleArn: schedulerRole.arn,
        // 失敗しても再試行しない（仕様書 5.3）。次の 60 秒に任せる。
        retryPolicy: { maximumRetryAttempts: 0 },
    },
});

// ---------------------------------------------------------------------------
// 出力
// ---------------------------------------------------------------------------

export const publicBucketOut = publicBucket.name;
export const stateBucketOut = stateBucket.name;
export const r2EndpointOut = r2Endpoint;
export const functionName = refresh.name;
export const logGroupName = logGroup.name;
export const cacheRulesetId = cacheRuleset.id;
// カスタムドメインを手で繋ぐときの相手。
export const deliveryUrl = `https://${deliveryHost}/v1/status.json`;
