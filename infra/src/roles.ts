import * as aws from "@pulumi/aws";

import { onAws } from "./providers";
import { prefix, workloadBoundaryName } from "./settings";

const assumeRolePolicy = (service: string) =>
    JSON.stringify({
        Version: "2012-10-17",
        Statement: [
            {
                Effect: "Allow",
                Principal: { Service: service },
                Action: "sts:AssumeRole",
            },
        ],
    });

// 境界の ARN は設定に持たない。アカウント ID が入るためである（#26）。
// 名前だけを設定から取り、いま繋いでいるアカウントと組み合わせて ARN にする。
//
// 引く先はデプロイ先と同じアカウントに限る。onAws を渡すのは、既定の資格情報では
// なく AWS プロバイダのものを見せるためである（R2 をバックエンドにしていると
// AWS_* には R2 の鍵が入っている。providers.ts を参照）。
//
// デプロイロールへの権限追加は要らない。sts:GetCallerIdentity は誰でも呼べる。
//
// 設定が空なら引かない。手元からのデプロイでは境界を付けない道を残してある。
const workloadBoundaryArn = workloadBoundaryName
    ? aws.getCallerIdentityOutput({}, onAws).accountId.apply(
          (account) => `arn:aws:iam::${account}:policy/${workloadBoundaryName}`,
      )
    : undefined;

// 実行時のロールには権限境界を付ける。境界は上限であって付与ではないので、
// ここに無いものは、あとで足したポリシーで許しても効かない。
// 中身は docs/aws-oidc.md にある。
export const lambdaRole = new aws.iam.Role(
    "lambda",
    {
        name: `${prefix}-lambda`,
        permissionsBoundary: workloadBoundaryArn,
        assumeRolePolicy: assumeRolePolicy("lambda.amazonaws.com"),
    },
    onAws,
);

// EventBridge Scheduler は自前のロールで対象を呼ぶ。
// EventBridge のルールと違い、関数側のリソースポリシーでは足りない。
export const schedulerRole = new aws.iam.Role(
    "scheduler",
    {
        name: `${prefix}-scheduler`,
        permissionsBoundary: workloadBoundaryArn,
        assumeRolePolicy: assumeRolePolicy("scheduler.amazonaws.com"),
    },
    onAws,
);
