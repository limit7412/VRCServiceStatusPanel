import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

import { onAws } from "./providers";
import { prefix, ytdlpVersion } from "./settings";

// yt-dlp と QuickJS を載せた Layer（仕様書 7.1、7.3）。
//
// zip は backend/layer/build.sh が作る。infra/deploy.sh が pulumi up の前に
// 必ず呼ぶので、ここでは出来ている前提で参照する。無ければ up がファイルを
// 読めずに止まる。build.sh は同じ版の zip が既にあれば何もしないので、
// 取り直しが走るのは版を変えたときだけである。
//
// Pulumi に持たせるのは、発行と関数への反映を一つの up の中で揃えるためである。
// 手で発行して ARN を写す形だと、Layer を作り直したのに関数が古い版を指した
// ままになる余地が残る（#8）。
//
// zip が変わったときだけ新しい版が出来る。中身は関数のバイナリと別なので、
// バックエンドを直しただけのデプロイでは 36 MiB は上がらない。
//
// ytdlpVersion だけを書き換えて up を流すと、description が変わるので新しい版が
// 出来るが、中身は前の zip のままになる。deploy.sh は up の前に必ず build.sh を
// 呼ぶのでそうはならない。手で並べる場合は README の順に従う。
export const ytdlpLayer = new aws.lambda.LayerVersion(
    "ytdlp",
    {
        // 名前にスタック名を含める。仕様書 7.3 が中身で決まる不変の成果物として
        // 一つに寄せていたのは、手で一度だけ発行して dev と prod で共有する
        // 前提だったためである。Pulumi に持たせると、二つのスタックが同じ
        // Layer 名へ別々に版を積み、互いの版を知らないまま自分の ARN だけを
        // state に持つことになる。スタックごとに 36 MiB 増えるが、Layer と
        // デプロイパッケージの合計枠はアカウントあたり 75 GB なので届かない。
        layerName: `${prefix}-ytdlp`,
        code: new pulumi.asset.FileArchive("../backend/ytdlp-layer.zip"),
        // 関数と揃える。ずれていても発行はできるが、結ぶときに弾かれる。
        compatibleRuntimes: ["provided.al2023"],
        compatibleArchitectures: ["arm64"],
        description: `yt-dlp ${ytdlpVersion}`,
    },
    onAws,
);
