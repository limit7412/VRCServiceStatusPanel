import * as aws from "@pulumi/aws";

import { awsRegion } from "./settings";

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
export const awsProvider = new aws.Provider(
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

/** AWS 側のリソースにはこれを渡す。Cloudflare 側には要らない */
export const onAws = { provider: awsProvider };
