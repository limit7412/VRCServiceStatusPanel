/**
 * 関数ひとつ分の指定。
 *
 * handler は `_HANDLER` として関数へ渡り、backend/src/main.cr の
 * `Runtime::Lambda.handler` の名前と一致したものが動く。
 * 名前がずれると関数は起動時に落ちるので、両方を揃えること。
 */
export interface FunctionSpec {
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
// 実際に組み立てるのは src/compute.ts である。
export const FUNCTIONS: FunctionSpec[] = [
    {
        handler: "refresh",
        description: "上流を取得して配信 JSON を書き出す",
        // 60 秒間隔で起動する（仕様書 5.1）
        schedule: "rate(1 minute)",
        // dev の実測から決めた（仕様書 5.1）。
        // メモリは GC のヒープが 149 MB で頭打ちになり、256 MB はその 1.7 倍である。
        // 時間は一回 2〜3 秒で、上流が全部 5 秒で切れても R2 と合わせて 7 秒に
        // 収まる。15 秒はその倍で、Scheduler の 60 秒間隔に重なることも無い。
        memorySize: 256,
        timeout: 15,
    },
];
