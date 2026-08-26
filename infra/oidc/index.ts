import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

// GitHub Actions から AWS へ入るための入口と、実行時ロールの上限を定義する。
//
// 本体（infra/）から切り離してあるのは、ここが CI の権限そのものを決める場所
// だからである。同じプログラムに置くと、CI が自分の権限を書き換えられることに
// なり、境界も入口も意味を失う。これは手元からだけ流す。
//
// 手元から流すので、資格情報は管理者のものでよい。R2 をバックエンドにしている
// 場合の DEPLOY_AWS_* の写し替えは本体と同じで、README にある。

const config = new pulumi.Config();

// スタック名の上限。
//
// ここで作る `<頭>-<スタック名>-github-deploy` がいちばん厳しい。
// IAM ロール名の上限が 64 文字で、頭と接尾で 48 文字を使う。
// 本体（infra/src/settings.ts）とも揃えてある。
const MAX_STACK_NAME = 16;

/**
 * スタック名を物理名に使えるか確かめる。
 *
 * Pulumi のスタック名はここより緩く、大文字も `_` も長い名前も通る。
 * そのまま物理名にすると AWS が長さで弾くが、実際に作りに行くまで
 * 分からないので、ここで止める。
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

// 権限を渡す相手は本体スタックである。スタック名を揃えて運用する。
// 揃えたくない場合だけ targetStack で明示する。
const targetStack = checkStackName(config.get("targetStack") || pulumi.getStack());
const prefix = `qazx7412-vrc-service-status-panel-${targetStack}`;

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

const awsAccountId = aws.getCallerIdentityOutput({}, { provider: awsProvider }).accountId;

// ---------------------------------------------------------------------------
// 実行時ロールの権限境界
// ---------------------------------------------------------------------------

// 境界は上限であって付与ではない。ここに無いものは、ロールのポリシーで
// 許しても効かない。デプロイロールが乗っ取られて実行ロールへ強い権限を
// 足しても、この上限を超えられない。
//
// これが無いと次の順で昇格できる。
//   1. デプロイロールで実行ロールへ任意のポリシーを足す
//   2. lambda:UpdateFunctionCode でコードを差し替える
//   3. 次の起動でその権限のまま動く
//
// 境界の中身を決めるのはこちら側の仕事であって、CI の仕事ではない。
// だからこのポリシーも本体ではなくここに置く。
const workloadBoundary = new aws.iam.Policy(
    "workload-boundary",
    {
        name: `${prefix}-workload-boundary`,
        description: "集約サーバーの実行時ロールが超えられない上限",
        policy: awsAccountId.apply((account) =>
            JSON.stringify({
                Version: "2012-10-17",
                Statement: [
                    {
                        // 記録を書く。ロググループ自体は作らせない
                        Sid: "WriteOwnLogs",
                        Effect: "Allow",
                        Action: ["logs:CreateLogStream", "logs:PutLogEvents"],
                        Resource: `arn:aws:logs:${awsRegion}:${account}:log-group:/aws/lambda/${prefix}-*:*`,
                    },
                    {
                        // Scheduler がこのスタックの関数を呼ぶ
                        Sid: "InvokeOwnFunctions",
                        Effect: "Allow",
                        Action: "lambda:InvokeFunction",
                        Resource: `arn:aws:lambda:${awsRegion}:${account}:function:${prefix}-*`,
                    },
                ],
            }),
        ),
    },
    onAws,
);

// ---------------------------------------------------------------------------
// OIDC の入口とデプロイロール
// ---------------------------------------------------------------------------

const githubRepository = config.require("githubRepository");

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

// 本体スタックが触る範囲だけを与える。
//
// 名前の頭で絞っているので、同じアカウントの他のリソースへは届かない。
// スタック名まで含めて絞るのは、同じアカウントに dev と prod を並べたとき、
// 片方のデプロイロールがもう片方へ手を伸ばせないようにするためである。
//
// ただし deployRole 自身もその範囲に入るため、権限を書き換えて広げられる。
// それを塞ぐ Deny を最後に置いてある。
new aws.iam.RolePolicy(
    "github-deploy",
    {
        name: "deploy",
        role: deployRole.id,
        policy: pulumi
            .all([awsAccountId, deployRole.arn, workloadBoundary.arn])
            .apply(([account, roleArn, boundaryArn]) => {
                const fn = `arn:aws:lambda:${awsRegion}:${account}:function:${prefix}-*`;
                const layer = `arn:aws:lambda:${awsRegion}:${account}:layer:qazx7412-vrc-service-status-panel-*`;
                const role = `arn:aws:iam::${account}:role/${prefix}-*`;
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
                                // 同時実行もランタイムの更新方式も指定していないが、
                                // 差分を見るときに読まれる
                                "lambda:GetFunctionConcurrency",
                                "lambda:GetRuntimeManagementConfig",
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
                            // Layer は関数へ結ぶときに読む（仕様書 7.1、7.3）。
                            // 発行は手元から行うのでここには要らない。
                            //
                            // スタック名で絞らないのは、Layer が中身で決まる
                            // 不変の成果物で、dev と prod で同じものを指すためである。
                            Sid: "Layers",
                            Effect: "Allow",
                            Action: ["lambda:GetLayerVersion", "lambda:ListLayerVersions"],
                            Resource: layer,
                        },
                        {
                            // 読み取りと受け渡し。境界の有無に関わらず要る
                            Sid: "ReadRoles",
                            Effect: "Allow",
                            Action: [
                                "iam:GetRole",
                                "iam:GetRolePolicy",
                                "iam:ListRolePolicies",
                                "iam:ListAttachedRolePolicies",
                                "iam:ListRoleTags",
                                "iam:PassRole",
                                "iam:TagRole",
                                "iam:UntagRole",
                            ],
                            Resource: role,
                        },
                        {
                            // ロールを作るとき、境界を付け替えるとき。
                            // どちらも要求そのものに境界の ARN が入るので、
                            // iam:PermissionsBoundary で縛れる。
                            //
                            // 境界の無いロールを作られると、そこへ任意の権限を足して
                            // lambda:UpdateFunctionCode で乗っ取れてしまう。
                            Sid: "CreateBoundedRoles",
                            Effect: "Allow",
                            Action: ["iam:CreateRole", "iam:PutRolePermissionsBoundary"],
                            Resource: role,
                            Condition: {
                                StringEquals: { "iam:PermissionsBoundary": boundaryArn },
                            },
                        },
                        {
                            // 既にこの境界が付いているロールに対してだけ、
                            // ポリシーを足し引きできる。
                            //
                            // この条件キーは相手のロールに付いている境界を見るもので、
                            // 要求に境界が入らないこれらの操作でも成立する。AWS の
                            // 権限委譲の例も、同じ条件を PutUserPolicy などへ掛けている。
                            Sid: "WriteBoundedRolePolicies",
                            Effect: "Allow",
                            Action: [
                                "iam:PutRolePolicy",
                                "iam:DeleteRolePolicy",
                                "iam:AttachRolePolicy",
                                "iam:DetachRolePolicy",
                            ],
                            Resource: role,
                            Condition: {
                                StringEquals: { "iam:PermissionsBoundary": boundaryArn },
                            },
                        },
                        {
                            // 削除と信頼ポリシーの更新には条件を掛けない。
                            // この二つは AWS が挙げる iam:PermissionsBoundary の
                            // 対象に入っておらず、掛けると Allow が成立しなくなる。
                            //
                            // 緩くしても昇格には繋がらない。境界の無いロールは
                            // 上の条件で作れないため、ここへ届く相手はどれも
                            // 境界付きであり、信頼先を書き換えても上限は変わらない。
                            Sid: "WriteRoles",
                            Effect: "Allow",
                            Action: ["iam:DeleteRole", "iam:UpdateAssumeRolePolicy"],
                            Resource: role,
                        },
                        {
                            // 境界を外す道を塞ぐ。
                            // Deny は Allow に優先するので、上の Condition を
                            // 満たしていても通らない。
                            Sid: "DenyBoundaryRemoval",
                            Effect: "Deny",
                            Action: "iam:DeleteRolePermissionsBoundary",
                            Resource: role,
                        },
                        {
                            // 境界の中身を書き換える道も塞ぐ。
                            // このスタックを手元からしか流さない以上、CI に
                            // 書き込みの Allow は無いが、上限を決める場所なので
                            // 明示的に閉じておく。
                            Sid: "DenyBoundaryEdit",
                            Effect: "Deny",
                            Action: [
                                "iam:CreatePolicyVersion",
                                "iam:DeletePolicy",
                                "iam:DeletePolicyVersion",
                                "iam:SetDefaultPolicyVersion",
                            ],
                            Resource: boundaryArn,
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
                            // 自分の権限は書き換えさせない。
                            // 読み取りは残す。上の ReadRoles がこのロールにも
                            // 掛かっており、塞ぐ理由が無い。
                            //
                            // このロール自体を変えるときは、手元からこのスタックを流す。
                            Sid: "DenySelfEscalation",
                            Effect: "Deny",
                            Action: [
                                "iam:AttachRolePolicy",
                                "iam:DetachRolePolicy",
                                "iam:DeleteRole",
                                "iam:DeleteRolePolicy",
                                "iam:PutRolePolicy",
                                "iam:PutRolePermissionsBoundary",
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

// ---------------------------------------------------------------------------
// 出力
// ---------------------------------------------------------------------------

// 本体スタックの workloadBoundaryArn に入れる。
export const workloadBoundaryArn = workloadBoundary.arn;
// GitHub Actions の configure-aws-credentials に渡す（README を参照）。
export const githubDeployRoleArn = deployRole.arn;
export const oidcProviderArnOut = pulumi.output(oidcProviderArn);
