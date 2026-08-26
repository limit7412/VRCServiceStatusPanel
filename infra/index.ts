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
// AWS プロバイダ
// ---------------------------------------------------------------------------

// 状態を R2 へ置くと、そのバックエンドが AWS_ACCESS_KEY_ID と
// AWS_SECRET_ACCESS_KEY から R2 の鍵を読む。AWS プロバイダの既定の探索順は
// この環境変数を共有プロファイルより先に見るため、そのままでは Lambda の
// 操作にも R2 の鍵が使われて認証に失敗する。
//
// DEPLOY_AWS_* を AWS プロバイダから見た AWS_* へ写して切り分ける。
// 写しは元の変数がある場合だけ効くので、R2 バックエンドを使わない環境では
// 何も変わらず、aws configure の資格情報がそのまま使われる。
//
// 写せるのは鍵だけで、プロファイルでは代わりにならない。
// AWS_PROFILE を写しても AWS_ACCESS_KEY_ID は R2 のまま残り、
// 環境変数のほうが共有プロファイルより先に見られる。
// R2 をバックエンドにするなら、AWS 側は鍵で渡すことになる。
//
// 明示したプロバイダはスタック設定の aws:region を自動では読まないため、
// ここで取り出して渡す。既定は仕様書 5.1 の東京である。
const awsRegion = new pulumi.Config("aws").get("region") ?? "ap-northeast-1";

const awsProvider = new aws.Provider(
    "aws",
    { region: awsRegion },
    {
        envVarMappings: {
            DEPLOY_AWS_ACCESS_KEY_ID: "AWS_ACCESS_KEY_ID",
            DEPLOY_AWS_SECRET_ACCESS_KEY: "AWS_SECRET_ACCESS_KEY",
            DEPLOY_AWS_SESSION_TOKEN: "AWS_SESSION_TOKEN",
        },
    },
);

const onAws = { provider: awsProvider };

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
// このゾーンの http_request_cache_settings に、既に Cache Rules があると作成は
// 失敗する。kind: "zone" のこのフェーズはゾーンごとに一つしか置けないためである。
// 既にあるなら pulumi import で取り込み、規則をここへ並べ直す。手順は README にある。
//
// 自動で取り込んで混ぜることはしない。こちらが置いた覚えのない規則を
// 黙って管理下に入れると、次の pulumi up でそれを消してしまう。
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
// 当面はダッシュボードから繋ぐ。手順は infra/README.md にある。
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

// 仕様書 11.7 が挙げる環境変数。関数はどれも同じものを受け取る。
// main.cr は欠けていれば起動時に落とす。
const environment = {
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
};

// ---------------------------------------------------------------------------
// 集約サーバー（仕様書 5.1）
// ---------------------------------------------------------------------------

/**
 * 関数ひとつ分の指定。
 *
 * handler は `_HANDLER` として関数へ渡り、backend/src/main.cr の
 * `Runtime::Lambda.handler` の名前と一致したものが動く。
 * 名前がずれると関数は起動時に落ちるので、両方を揃えること。
 */
interface FunctionSpec {
    /** handler 名。main.cr の HANDLERS と揃える */
    handler: string;
    description: string;
    /** 起動間隔。省略すると定期起動しない */
    schedule?: string;
    memorySize: number;
    /** 秒 */
    timeout: number;
}

// 関数を増やすときはここへ足し、main.cr にも同じ名前の handler を足す。
// バイナリは一つで、handler の文字列だけが違う。
const FUNCTIONS: FunctionSpec[] = [
    {
        handler: "refresh",
        description: "上流を取得して配信 JSON を書き出す",
        // 60 秒間隔で起動する（仕様書 5.1）
        schedule: "rate(1 minute)",
        // yt-dlp を動かす余裕を見込む（仕様書 5.1）
        memorySize: 512,
        timeout: 40,
    },
];

// OIDC のロールは任意なので、作られなければ未定義のまま出力する。
let githubDeployRoleArn: pulumi.Output<string> | undefined;

const lambdaRole = new aws.iam.Role(
    "lambda",
    {
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
    },
    onAws,
);

// EventBridge Scheduler は自前のロールで対象を呼ぶ。
// EventBridge のルールと違い、関数側のリソースポリシーでは足りない。
const schedulerRole = new aws.iam.Role(
    "scheduler",
    {
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
    },
    onAws,
);

// backend/build.sh が作った zip をそのまま渡す。
//
// ディレクトリから AssetArchive を組むと実行権限が落ち、provided ランタイムが
// bootstrap を起動できない。出来上がった zip を渡せば、モードは zip の中の
// 記録がそのまま使われる。関数が増えても同じ zip を使い回す。
const code = new pulumi.asset.FileArchive("../backend/bootstrap.zip");

const logGroups: aws.cloudwatch.LogGroup[] = [];
const functions: aws.lambda.Function[] = [];

for (const spec of FUNCTIONS) {
    // ロググループを先に作る。Lambda に任せると保持期間が無期限になり、
    // 60 秒ごとの記録が消えずに溜まり続ける。
    const logGroup = new aws.cloudwatch.LogGroup(
        spec.handler,
        {
            name: `/aws/lambda/${prefix}-${spec.handler}`,
            retentionInDays: 14,
        },
        onAws,
    );
    logGroups.push(logGroup);

    const fn = new aws.lambda.Function(
        spec.handler,
        {
            name: `${prefix}-${spec.handler}`,
            description: spec.description,
            role: lambdaRole.arn,
            code,
            // provided ランタイムが動かすのは zip 直下の bootstrap で、
            // この文字列は _HANDLER として渡る。
            handler: spec.handler,
            runtime: "provided.al2023",
            architectures: ["arm64"],
            memorySize: spec.memorySize,
            timeout: spec.timeout,
            layers: [ytdlpLayerArn],
            loggingConfig: {
                logFormat: "Text",
                logGroup: logGroup.name,
            },
            environment: { variables: environment },
        },
        { ...onAws, dependsOn: [logGroup] },
    );
    functions.push(fn);

    if (spec.schedule === undefined) {
        continue;
    }

    new aws.scheduler.Schedule(
        spec.handler,
        {
            name: `${prefix}-${spec.handler}`,
            description: spec.description,
            scheduleExpression: spec.schedule,
            // 揺らぎを入れない。決めた間隔で動かしたい。
            flexibleTimeWindow: { mode: "OFF" },
            target: {
                arn: fn.arn,
                roleArn: schedulerRole.arn,
                // 失敗しても再試行しない（仕様書 5.3）。次の起動に任せる。
                retryPolicy: { maximumRetryAttempts: 0 },
            },
        },
        onAws,
    );
}

// 権限は関数をすべて作ってからまとめて与える。
// 関数ごとに作ると、関数を足すたびにポリシーも増える。
new aws.iam.RolePolicy(
    "lambda-logs",
    {
        name: "logs",
        role: lambdaRole.id,
        policy: pulumi.all(logGroups.map((group) => group.arn)).apply((arns) =>
            JSON.stringify({
                Version: "2012-10-17",
                Statement: [
                    {
                        Effect: "Allow",
                        Action: ["logs:CreateLogStream", "logs:PutLogEvents"],
                        Resource: arns.map((arn) => `${arn}:*`),
                    },
                ],
            }),
        ),
    },
    onAws,
);

new aws.iam.RolePolicy(
    "scheduler-invoke",
    {
        name: "invoke",
        role: schedulerRole.id,
        policy: pulumi.all(functions.map((fn) => fn.arn)).apply((arns) =>
            JSON.stringify({
                Version: "2012-10-17",
                Statement: [
                    {
                        Effect: "Allow",
                        Action: "lambda:InvokeFunction",
                        Resource: arns,
                    },
                ],
            }),
        ),
    },
    onAws,
);

// ---------------------------------------------------------------------------
// GitHub Actions から AWS へ入るための OIDC（任意）
// ---------------------------------------------------------------------------

// githubRepository を設定したときだけ作る。
// 手元からしかデプロイしない構成では要らない。
//
// 空文字も未設定として扱う。Pulumi.yaml の宣言に既定値を置いており、
// 設定しなければ空文字で解決されるためである。
const githubRepository = config.get("githubRepository") || undefined;

if (githubRepository !== undefined) {
    const identity = aws.getCallerIdentityOutput({}, { provider: awsProvider });

    // GitHub の OIDC プロバイダはアカウントに一つしか置けない。
    // 他のリポジトリのために既に作ってあるなら、その ARN を設定で渡す。
    const existingProviderArn = config.get("githubOidcProviderArn") || undefined;

    const oidcProviderArn =
        existingProviderArn ??
        new aws.iam.OpenIdConnectProvider(
            "github",
            {
                url: "https://token.actions.githubusercontent.com",
                // OIDC で受け取った JWT の aud に入る値。
                clientIdLists: ["sts.amazonaws.com"],
                // thumbprintLists は渡さない。GitHub を含むいくつかの発行者について、
                // AWS は自前の信頼された CA で検証し、指紋を見ない。
                // 一度渡すと外しても設定に残り続けるので、初めから置かない。
            },
            onAws,
        ).arn;

    // 誰がこのロールを使えるか。既定は master への push に限る。
    //
    // sub を絞らないと、同じ発行者の JWT を持つ任意のリポジトリから
    // このロールを引ける。GitHub Actions の OIDC でいちばん間違えやすい箇所である。
    const configured = config.getObject<string[]>("githubDeploySubjects");
    const subjects = configured !== undefined && configured.length > 0 ? configured : [
        `repo:${githubRepository}:ref:refs/heads/master`,
    ];

    const deployRole = new aws.iam.Role(
        "github-deploy",
        {
            name: `${prefix}-github-deploy`,
            description: `${githubRepository} の GitHub Actions からデプロイする`,
            assumeRolePolicy: pulumi.all([oidcProviderArn]).apply(([arn]) =>
                JSON.stringify({
                    Version: "2012-10-17",
                    Statement: [
                        {
                            Effect: "Allow",
                            Principal: { Federated: arn },
                            Action: "sts:AssumeRoleWithWebIdentity",
                            Condition: {
                                StringEquals: {
                                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                                },
                                StringLike: {
                                    "token.actions.githubusercontent.com:sub": subjects,
                                },
                            },
                        },
                    ],
                }),
            ),
        },
        onAws,
    );

    // このスタックが触る範囲だけを与える。
    //
    // 名前の頭で絞っているので、同じアカウントの他のリソースへは届かない。
    // ただし deployRole 自身もその範囲に入るため、権限を書き換えて広げられる。
    // それを塞ぐ Deny を最後に置いてある。
    new aws.iam.RolePolicy(
        "github-deploy",
        {
            name: "deploy",
            role: deployRole.id,
            policy: pulumi
                .all([identity.accountId, deployRole.arn, pulumi.output(oidcProviderArn)])
                .apply(([account, roleArn, providerArn]) => {
                    const fn = `arn:aws:lambda:${awsRegion}:${account}:function:${prefix}-*`;
                    const layer = `arn:aws:lambda:${awsRegion}:${account}:layer:vrc-service-status-panel-*`;
                    const role = `arn:aws:iam::${account}:role/vrc-service-status-panel-*`;
                    const logs = `arn:aws:logs:${awsRegion}:${account}:log-group:/aws/lambda/${prefix}-*`;
                    const schedule = `arn:aws:scheduler:${awsRegion}:${account}:schedule/default/${prefix}-*`;

                    return JSON.stringify({
                        Version: "2012-10-17",
                        Statement: [
                            {
                                Sid: "Functions",
                                Effect: "Allow",
                                Action: [
                                    "lambda:CreateFunction",
                                    "lambda:DeleteFunction",
                                    "lambda:GetFunction",
                                    "lambda:GetFunctionConfiguration",
                                    "lambda:GetFunctionCodeSigningConfig",
                                    "lambda:GetPolicy",
                                    "lambda:ListVersionsByFunction",
                                    "lambda:ListTags",
                                    "lambda:TagResource",
                                    "lambda:UntagResource",
                                    "lambda:UpdateFunctionCode",
                                    "lambda:UpdateFunctionConfiguration",
                                ],
                                Resource: fn,
                            },
                            {
                                // Layer の発行と、関数へ結ぶときの参照（仕様書 7.1、7.3）
                                Sid: "Layers",
                                Effect: "Allow",
                                Action: [
                                    "lambda:PublishLayerVersion",
                                    "lambda:DeleteLayerVersion",
                                    "lambda:GetLayerVersion",
                                    "lambda:ListLayerVersions",
                                ],
                                Resource: layer,
                            },
                            {
                                // 実行ロールと Scheduler のロールを作り、関数へ渡す
                                Sid: "Roles",
                                Effect: "Allow",
                                Action: [
                                    "iam:CreateRole",
                                    "iam:DeleteRole",
                                    "iam:GetRole",
                                    "iam:ListRolePolicies",
                                    "iam:ListAttachedRolePolicies",
                                    "iam:ListRoleTags",
                                    "iam:PassRole",
                                    "iam:TagRole",
                                    "iam:UntagRole",
                                    "iam:UpdateAssumeRolePolicy",
                                    "iam:PutRolePolicy",
                                    "iam:GetRolePolicy",
                                    "iam:DeleteRolePolicy",
                                ],
                                Resource: role,
                            },
                            {
                                Sid: "LogGroups",
                                Effect: "Allow",
                                Action: [
                                    "logs:CreateLogGroup",
                                    "logs:DeleteLogGroup",
                                    "logs:PutRetentionPolicy",
                                    "logs:DeleteRetentionPolicy",
                                    "logs:ListTagsForResource",
                                    "logs:TagResource",
                                    "logs:UntagResource",
                                ],
                                Resource: logs,
                            },
                            {
                                // 一覧はリソース単位で絞れない
                                Sid: "DescribeLogGroups",
                                Effect: "Allow",
                                Action: "logs:DescribeLogGroups",
                                Resource: "*",
                            },
                            {
                                Sid: "Schedules",
                                Effect: "Allow",
                                Action: [
                                    "scheduler:CreateSchedule",
                                    "scheduler:DeleteSchedule",
                                    "scheduler:GetSchedule",
                                    "scheduler:UpdateSchedule",
                                    "scheduler:ListTagsForResource",
                                    "scheduler:TagResource",
                                    "scheduler:UntagResource",
                                ],
                                Resource: schedule,
                            },
                            {
                                // このスタックが OIDC プロバイダを作った場合、pulumi は
                                // 差分を見るときにそれを読む。読めないと refresh が落ちる。
                                //
                                // 読み取りだけにする。プロバイダはアカウントに一つしかなく、
                                // 他のリポジトリも使っている可能性がある。CI から書き換え
                                // させると、その巻き添えが出る。
                                Sid: "ReadOidcProvider",
                                Effect: "Allow",
                                Action: [
                                    "iam:GetOpenIDConnectProvider",
                                    "iam:ListOpenIDConnectProviderTags",
                                ],
                                Resource: providerArn,
                            },
                            {
                                // 自分の権限は書き換えさせない。
                                // 読み取りは残す。Pulumi が毎回このロールの差分を見るため、
                                // GetRole まで塞ぐと CI からの pulumi up が通らなくなる。
                                //
                                // このロール自体を変えるときは、手元から pulumi up する。
                                Sid: "DenySelfEscalation",
                                Effect: "Deny",
                                Action: [
                                    "iam:AttachRolePolicy",
                                    "iam:DeleteRole",
                                    "iam:DeleteRolePolicy",
                                    "iam:PutRolePolicy",
                                    "iam:UpdateAssumeRolePolicy",
                                ],
                                Resource: roleArn,
                            },
                        ],
                    });
                }),
        },
        onAws,
    );

    githubDeployRoleArn = deployRole.arn;
}

// ---------------------------------------------------------------------------
// 出力
// ---------------------------------------------------------------------------

export const publicBucketOut = publicBucket.name;
export const stateBucketOut = stateBucket.name;
export const r2EndpointOut = r2Endpoint;
export const functionNames = pulumi.all(functions.map((fn) => fn.name));
export const logGroupNames = pulumi.all(logGroups.map((group) => group.name));
export const cacheRulesetId = cacheRuleset.id;
// GitHub Actions の configure-aws-credentials に渡す（README を参照）。
export const githubDeployRoleArnOut = githubDeployRoleArn;
// カスタムドメインを手で繋ぐときの相手。
export const deliveryUrl = `https://${deliveryHost}/v1/status.json`;
