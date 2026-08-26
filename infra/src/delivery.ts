import * as cloudflare from "@pulumi/cloudflare";

import {
    bucketLocation,
    cloudflareAccountId,
    deliveryHost,
    deliveryZoneId,
    publicBucketName,
    stateBucketName,
} from "./settings";

// 配信と内部の保存先（仕様書 6）。

// バケットを消すと配信も履歴も失う。protect を付けて、
// destroy や置き換えを伴う変更が誤って通らないようにする。
export const publicBucket = new cloudflare.R2Bucket(
    "public",
    {
        accountId: cloudflareAccountId,
        name: publicBucketName,
        location: bucketLocation,
    },
    { protect: true },
);

export const stateBucket = new cloudflare.R2Bucket(
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
export const cacheRuleset = new cloudflare.Ruleset("delivery-cache", {
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
