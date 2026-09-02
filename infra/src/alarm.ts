import * as aws from "@pulumi/aws";

import { onAws } from "./providers";
import { prefix, stack } from "./settings";

// 集約サーバーが止まったことを知らせる（仕様書 9）。
//
// これは backend の error/usecase.cr が送るアラートとは別の経路である。
// あちらは refresh が例外を出したときに関数が自分で送るので、関数が起動しない、
// Scheduler が止まる、Layer が壊れて bootstrap が上がらない、という場合は
// 何も送られない。止まったことを知らせるには、外から見ている誰かが要る。
//
// 送り先も分ける。関数が死んでいるときに関数へ転送させる形にすると、
// 見張る側が見張られる側と同じ足場に乗ることになる。
// SNS からのメールなら AWS の中だけで完結する。

/** メトリクスの名前空間と名前。backend/src/runtime/metrics.cr と揃える */
const NAMESPACE = "VRCServiceStatusPanel";
const METRIC = "RefreshSuccess";

/** 何分止まったら知らせるか（仕様書 9） */
const WINDOW_SECONDS = 300;

export const alertTopic = new aws.sns.Topic("alerts", { name: `${prefix}-alerts` }, onAws);

// 購読はここでは作らない。届け先は手で足す（infra/README.md の「手で行う作業」）。
//
// 届け先をスタックの設定に持たせると、その値が commit される。
// このリポジトリは public なので（仕様書 9）、メールアドレスを置けばそのまま公開される。
// secret にすれば暗号文になるが、そうすると値が Output になり、
// 「設定してあれば購読を作る」という条件そのものが書けなくなる。
//
// 手作業が一つ増えるわけでもない。メールの購読は AWS から届く確認のリンクを
// 開くまで PendingConfirmation のままで、そこはどのみち人の手が要る。
// Chatbot 経由の Slack のように、メール以外へ届けたい場合の余地も残る。

export const staleAlarm = new aws.cloudwatch.MetricAlarm(
    "refresh-stale",
    {
        name: `${prefix}-refresh-stale`,
        alarmDescription: `${stack} の配信が ${WINDOW_SECONDS / 60} 分止まっている`,

        namespace: NAMESPACE,
        metricName: METRIC,
        // 名前空間が同じでもスタックが違えば別の系列になる。
        dimensions: { Env: stack },

        // 60 秒ごとに一つ出るはずのものを、5 分ぶん足す。
        // 一度でも配信まで終えていれば 1 以上になる。
        statistic: "Sum",
        period: WINDOW_SECONDS,
        evaluationPeriods: 1,
        threshold: 1,
        comparisonOperator: "LessThanThreshold",

        // 欠測を異常として扱う。
        //
        // 成功の行は成功したときにしか出ない。関数が一度も上がっていなければ、
        // 0 が並ぶのではなくデータ点そのものが無い。
        // 既定の missing は「判定しない」なので、そのままだと、いちばん知りたい
        // 「まったく動いていない」場合にアラームが鳴らずに INSUFFICIENT_DATA で
        // 止まる。
        treatMissingData: "breaching",

        alarmActions: [alertTopic.arn],
        // 直ったことも知らせる。鳴りっぱなしと復旧を見分けられる。
        okActions: [alertTopic.arn],
    },
    onAws,
);
