import * as aws from "@pulumi/aws";

import { onAws } from "./providers";
import { prefix, workloadBoundaryArn } from "./settings";

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

// 実行時のロールには権限境界を付ける。境界は上限であって付与ではないので、
// ここに無いものは、あとで足したポリシーで許しても効かない。
// 中身は infra/oidc/ にある。
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
