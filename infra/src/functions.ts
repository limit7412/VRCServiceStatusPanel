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
        // yt-dlp を動かしていたころの値である（仕様書 5.1）。
        // 外したあとの実測を見てから減らす
        memorySize: 512,
        timeout: 40,
    },
];
