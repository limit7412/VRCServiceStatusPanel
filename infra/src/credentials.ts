import * as crypto from "crypto";
import * as cloudflare from "@pulumi/cloudflare";
import * as pulumi from "@pulumi/pulumi";

import { publicBucket, stateBucket } from "./delivery";
import { cloudflareAccountId, prefix } from "./settings";

// R2 の鍵（仕様書 9）。
//
// Pulumi に発行させるのは、バケット名も鍵も、そのまま Lambda の環境変数に
// なるためである（仕様書 11.7）。人が写すと、鍵を替えたときに写し忘れる。

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
export const r2AccessKeyId = r2Token.id;

export const r2SecretAccessKey = pulumi.secret(
    r2Token.value.apply((value) => crypto.createHash("sha256").update(value).digest("hex")),
);

export const r2Endpoint = `https://${cloudflareAccountId}.r2.cloudflarestorage.com`;
