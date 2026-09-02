# バックエンドの実装プラン

集約サーバー（`backend/`）を、仕様書（#1）の第 5 節と第 11 節の姿まで持っていく段取り。
仕様書が「何を作るか」を定め、この文書は「どの順で、何を確かめながら作るか」を定める。

いまの `refresh` は空の `Feed` を返すだけで、R2 へは何も書かない。
取得元は Statuspage 系の四つだけが写せる状態にあり、それを呼ぶ側と書き出す側が無い。
つまり、部品はあるのに端から端が繋がっていない。

繋がっていないあいだは、仕様書第 12 節の未決事項のうち実機でしか分からないものが、いつまでも分からない。
`awscr-s3` が R2 で `Cache-Control` 付きの PUT を通せるか、alpine の静的ビルドが CA 証明書を見つけられるか、arm64 の yt-dlp が Lambda で動くか。
どれも後ろへ回すほど、分かるのが遅くなる。

そこで、最初の段で Statuspage の四つだけを使って端から端を通し、以後は取得元を一つずつ足す。
取得元を足す作業は、仕様書第 11.6 節のとおり `main.cr` の配列へ加えるだけになる。

## いまの状態

| 範囲 | 仕様書 | 状態 |
| --- | --- | --- |
| 環境変数の解決 | 11.7 | `config.cr`。欠けていれば全部を列挙して落ちる |
| Runtime API、ログ、CA 証明書 | 5.1、11.2 | `runtime/lambda.cr` |
| 上流への GET の共通部分 | 5.4 | `upstream.cr`。名乗り、タイムアウト、接続の張り直し |
| 中核の型 | 11.4 | `status/models.cr`。`Feed#to_json` と `note` の整形まで |
| 取得元と書き出し先の契約 | 11.4 | `status/repository.cr` |
| 合成監視のヒステリシス | 3.3 | `status/usecase.cr` の `level_for_synthetic`。spec 付き |
| Statuspage 系の取得元 | 3.2 | `statuspage/`。条件付き GET と失敗時の扱いまで spec 付き |
| 書き出し先 | 6、11.2 | 無い（`r2/`） |
| 一回の実行の流れ | 5.2、11.5 | 無い（`Status::Usecase#refresh`） |
| 合成監視の取得元 | 3.3 | 無い（`youtube/`、`steam/`、`booth/`） |
| yt-dlp 検査と同梱版の照合 | 7 | 無い（`ytdlp/`、`vrchat_api/`） |
| 失敗時のアラート | 11.2 | 無い（`error/`） |
| 最終成功時刻のメトリクス | 9 | 無い |

## 進め方の決まり

段ごとに pull request を一つ出し、CI が緑になってから merge し、`dev` へ手で出して確かめる。
段の中で分かった仕様書の穴は、その段の pull request では埋めず、下の「仕様書へ書き戻すもの」へ集めて #1 に反映する。

中核（`status/`）には HTTP も S3 も持ち込まない（仕様書 11.3）。
この段取りで中核に触れるのは、型を二箇所だけ広げるときに限る（第 1 段の `State` の版と、第 2 段の `Observation` の一項目）。

spec の書き方は、既にあるものに揃える。
判定規則は偽の取得元と偽の書き出し先を渡して確かめ、上流の写像は固定した応答本文から確かめ、HTTP のやり取りは `statuspage/repository_spec.cr` と同じく手元に立てたサーバーで確かめる。
CI は arm64 の Ubuntu で回るので、外部プロセスを起動する spec もそこで動く。

## 第 1 段：R2 への書き出しと一回の実行の流れ

この段が終わると、Statuspage の四つだけで実際の `v1/status.json` が配信され始める。

### 追加する shard

`awscr-s3`（v0.10.0、2025 年 4 月）を `shard.yml` の `dependencies` に足す。
クライアントは `endpoint:` を受け取り、`put_object` は `headers:` に任意のヘッダを取る。
R2 のカスタムエンドポイントと `Cache-Control` 付き PUT は、この二つで表せる。

`crystal build --link-flags -static` がこの shard を含めて通るかは、この段で `backend/build.sh` を流して見る。
依存は `awscr-signer` 一つで、どちらも標準ライブラリの上に書かれているので、通らない理由は思い当たらない。
通らなければ、この段で分かる。

### `r2/repository.cr`

`Status::FeedRepository` を実装する。

| メソッド | 何をするか |
| --- | --- |
| `load_state` | 内部バケットの `state.json` を GET し、`State.from_json` で返す。無ければ `nil` |
| `save_state` | 内部バケットの `state.json` へ PUT。`Content-Type: application/json` |
| `save_feed` | 配信バケットの `v1/status.json` へ PUT。`Content-Type: application/json; charset=utf-8`、`Cache-Control: public, max-age=30` |

クライアントは `region` に `auto` を渡し、`endpoint` に `R2_ENDPOINT` を渡して作る。
`awscr-s3` はパス形式（`/<バケット>/<キー>`）で要求を組み、R2 はアカウントのエンドポイントでこの形式を受け付ける。

`load_state` は、オブジェクトが無い場合（`NoSuchKey`）と読めない場合を分けない。
どちらも `nil` を返し、後者だけをログに残す。
仕様書 5.2 が「前回の JSON が取得できない場合は履歴なしとして扱う」と定めており、読めない理由で処理を変える必要が無い。
ただし、鍵の誤りのような設定の問題は毎回起きるので、ログには例外の種類を出す。

PUT の失敗は例外のまま外へ出す。
仕様書 5.3 は再試行せず次回に任せると定めており、それは handler の側で「失敗として報告して終わる」ことで満たされる。

spec は手元に HTTP サーバーを立て、`endpoint` にその URL を渡して、PUT のパスと本文とヘッダを捕まえる。
署名の検証はしない。
署名が正しいかは実機の R2 が答える。

### `Status::State` にスキーマ版を足す

`State` には `Feed` の `v` にあたるものが無い。
`JSON::Serializable` は知らないキーを読み捨てるので、後で形を変えたとき、古い `state.json` を新しいコードが黙って空の履歴として読む。
合成監視の判定が一度リセットされるだけで害は小さいが、気付けない。

いまは `state.json` がまだ一度も書かれていない。
版を足す費用がいちばん安いのはこの段である。
`v` を持たせ、`load_state` は版が違えば `nil` を返してログに残す。

### `Status::Usecase#refresh`

仕様書 11.5 の順に進む。

1. `load_state` で前回の状態を得る。取れなければ空の `State`
2. 取得元ごとにファイバーを起こし、`observe` の結果を `Channel(Observation)` で集める。取得元の数だけ受け取れば待ち合わせは終わる
3. サービスごとに `History` を更新し、`source_kind` で規則を分けて `Level` を決める
4. 失敗した取得元は前回の `ServiceStatus` を引き継ぐ
5. `Feed` と `State` を組み立て、`save_state` の後に `save_feed` を呼ぶ

`observe` は例外を出さない契約だが、`refresh` の側でも `rescue` して失敗の `Observation` に読み替える。
契約を破った取得元が一つあっても、他のサービスの更新を止めないためである。

全体のタイムアウトは持たない。
HTTP は `Upstream` の 5 秒で個別に切れ、yt-dlp は第 3 段で 20 秒を持つ。
Lambda の 40 秒は、そのどれよりも十分に長い。

規則の分け方は次のとおりにする。

| 取得元 | 成功したとき | 失敗したとき |
| --- | --- | --- |
| official | `Observation#level` をそのまま使う | 前回の `level` と `note` を引き継ぎ、`checked_unix` を更新しない。前回の `checked_unix` から 5 分以上経っていれば `Unknown` |
| synthetic | `History` に `Success` を積み、`level_for_synthetic` で決める | `History` に `Failure` を積み、同じく `level_for_synthetic` で決める。`checked_unix` は更新する |

official と synthetic で失敗の意味が違う。
official の失敗は「判定の材料が取れなかった」ことで、上流のサービス自体が落ちたかは分からない。
synthetic の失敗は「対象に届かなかった」ことで、それ自体が判定の材料である。
仕様書 5.3 の「前回値を保持する」は前者にだけ当てはまり、後者に当てはめると、一回の失敗で `Degraded` にする 3.3 の表と両立しない。

`stale` は、成功した `Observation` が一つも無いときに真にする（仕様書 4）。

前回値が無いまま official の取得に失敗した場合は、仕様書に定めが無い。
`Unknown` とし、`note` は空、`checked_unix` は 0 にする。
0 は「一度も取得できていない」ことを表し、ワールド側は `checked_unix` を表示に使わない（仕様書 8.2）ので、値の選び方で壊れる箇所は無い。

spec は偽の取得元（固定の `Observation` を返す）と偽の書き出し先（メモリに持つ）を渡して、上の表の行を一つずつ確かめる。
`stale` の真偽、5 分の境界、前回値の引き継ぎ、`save_state` が `save_feed` より先に呼ばれることも、ここで見る。

### `main.cr`

コールドスタート時に、Statuspage の四つ（`vrchat`、`discord`、`cloudflare`、`twitch`）と `R2::Repository` を組み立て、`Usecase` に渡す。
VRChat の `component_names` は API、Auth、Websocket、Website とする（仕様書 3.2）。
実際の応答に無い名前は `components_for` が黙って落とすので、名前の食い違いはこの段の実機確認で見える。

handler が Runtime API へ返すものは、`Feed` 全体から小さな要約（`generated_unix`、`stale`、サービス数）に変える。
いまの形は経路を通すための暫定であって、Lambda の応答を読む相手はいない。

### この段で確かめること

`dev` へ出して、次を見る。

- CloudWatch のログに `load_state` の `nil`（初回）と、二回目以降の読み込みが出ること
- `curl -sI https://<配信ホスト>/v1/status.json` の `content-type`、`cache-control`、`cf-cache-status`
- 二回続けて取ったときに、30 秒以内なら `cf-cache-status: HIT` になること
- 内部バケットの `state.json` に `v` と四つのサービスが入っていること
- ログに証明書の失敗が無いこと（仕様書 12 の CA 証明書の未決事項）

## 第 2 段：合成監視の取得元

Steam と BOOTH は HTTP の GET だけで済む。
YouTube も oEmbed の段までは同じで、yt-dlp を要らない。
三つとも同じ形なので、一つの pull request にまとめてもよいし、BOOTH のお知らせだけを分けてもよい。

### `Observation` に「成功したが一部が落ちている」を足す

Steam の「ストアのみ失敗」と BOOTH の「片方のみ失敗」は、どちらも成功として扱いつつ level を 1 にする（仕様書 3.3）。
いまの `Observation` は成功と失敗しか区別できず、`latency` の超過も `Usecase` 側で見ている。

`Observation` に `partial : Bool` を足し、「成功したが一部が落ちている」ことを表す。
`Usecase` は `latency` の超過と `partial` のどちらかが真なら、`level_for_synthetic` に `latency_exceeded: true` を渡す。
中核の型に触れるのはこの一項目だけである。

### `steam/`

`ISteamWebAPIUtil/GetServerInfo/v1/` と `store.steampowered.com/` を並列に GET する。

| Web API | ストア | outcome |
| --- | --- | --- |
| 200 で JSON | 200 | `Success` |
| 200 で JSON | それ以外 | `Success`、`partial` |
| それ以外 | 問わず | `Failure` |

`latency` は Web API のものを使う。
主指標がそちらだからである。

### `booth/`

`booth.pm/ja` と商品ページを並列に GET し、両方失敗なら `Failure`、片方だけなら `Success` に `partial` を付ける。

お知らせページは 10 分間隔で取り、最新の告知の題名に「障害」か「メンテナンス」を含むものがあれば `note` に載せる。
level には使わない（仕様書 3.3）。

10 分の間隔は、取得元のインスタンスがメモリに持つ最終取得時刻で数える。
`State` には入れない。
インスタンスはコールドスタートで作り直されるので、コールドスタートのたびに一度余分に取ることになるが、60 秒間隔の関数がコールドスタートするのは日に数回で、上流への配慮としてはそれで足りる。
`statuspage/` が ETag と前回の本文をメモリに持つのと同じ扱いである。

題名の抽出は、お知らせページの HTML を手元で一度取って固定し、その構造に合わせて書く。
仕様書 12 が未決としているとおり、この文書を書いている時点で構造は見ていない。
HTML の解析には shard を使わず、題名を囲む要素だけを文字列で探す。
構造が変わって見つからなくなったら、`note` を空にしてログに残す。
お知らせは表示だけの補助なので、取れないことで level が動いてはならない。

### `youtube/`（oEmbed の段まで）

`oembed?url=<固定動画 URL>&format=json` を GET し、200 なら `Success`、それ以外なら `Failure` とする。
第 3 段で yt-dlp の判定が加わるので、`ytdlp/` の検査は差し替えられる依存として受け取り、この段では渡さない。

### リダイレクトの扱い

Crystal の `HTTP::Client` はリダイレクトを追わない。
仕様書 3.3 は「200 で返るか」を条件にしているので、3xx はそのまま失敗として数える。
`booth.pm/ja` と `store.steampowered.com/` が 200 を直接返すかは、この段の実機確認で見る。
リダイレクトが返るなら、追うのではなく、200 を返す URL に付け替える。
追うと、リダイレクト先の障害と元の障害が区別できなくなる。

### bot 検知の扱い

この段の取得元は、403 や 503 を bot 検知として `Indeterminate` にはしない。
仕様書 3.3 が bot 検知を定めているのは yt-dlp の stderr だけで、HTTP の状態コードだけからは区別が付かない。
AWS の IP からの GET が Cloudflare のチャレンジに当たる可能性はあるので、`dev` で数日分のログを見て、必要なら判定を足す。

### `main.cr` の並び

`services` の順序は配信 JSON の表示順になる（仕様書 4）。
次の順にする。

1. `vrchat`
2. `youtube`
3. `steam`
4. `booth`
5. `discord`
6. `cloudflare`
7. `twitch`

来訪者が最初に疑うものを上に置き、公式ページを持つ周辺サービスを下に置いた。
仕様書は「集約サーバーの設定で固定する」としか定めていないので、この並びは仕様書へ書き戻す。

## 第 3 段：yt-dlp 検査と同梱版の照合

Layer は既に Pulumi が出している。
この段で初めて、Layer の中身が Lambda で動くかが分かる。

### `ytdlp/repository.cr`

`/opt/bin/yt-dlp_linux` を仕様書 7.1 の引数で起動し、終了コードと stdout と stderr から結果を三つに分ける（仕様書 7.2）。

| 条件 | 結果 |
| --- | --- |
| 終了コード 0、stdout の JSON の `formats` が空でない | 成功 |
| 終了コード非 0、stderr にサインイン要求か bot 検知の文言 | 判定不能 |
| それ以外 | 失敗 |

bot 検知の文言は、yt-dlp が出す "Sign in to confirm you're not a bot" を起点にし、実際に `dev` で見た文言を足していく。
文言の一覧は定数として一箇所に置く。

`HOME` と `--cache-dir` は `/tmp` に向ける（仕様書 7.1）。
yt-dlp のスタンドアロン版は起動のたびに `/tmp` へ自身を展開するので、その時間が 20 秒の中に入る。
`TMPDIR` も `/tmp` にしておく。

20 秒のタイムアウトは、`Process` を待つファイバーと `select` の `timeout` で作る。
時間切れなら `Signal::KILL` を送り、失敗として扱う。
`Process#wait` とパイプの読み取りはどちらもイベントループに乗るので、他の取得元の HTTP と並行して走る。

実行ファイルのパスはコンストラクタで受け取る。
spec では、固定の stdout と stderr と終了コードを返すシェルスクリプトを `spec/ytdlp/fixtures/` に置いて渡す。
CI は arm64 の Ubuntu なので、そのまま動く。

### `vrchat_api/`

`https://api.vrchat.cloud/api/1/config` を GET し、`youtubedl_version` を返す。
`User-Agent` は他の上流と同じ（仕様書 7.3）。

キー名と値の形式は、この文書を書いている時点で実応答を見ていない。
手元から一度取り、その応答を固定して `models_spec.cr` に置いてから書く。
値が公式リリースのタグ（`2025.09.26` の形）と一致するかも、そこで分かる。

取得は実行ごとに行う（仕様書 7.3）。
60 秒に一度の GET で、版が変わるのは VRChat クライアントの更新時だけなので、間隔を空ける余地はある。
まずは仕様書のとおりにし、負荷が気になれば BOOTH のお知らせと同じ形でメモリに持つ。

### `youtube/` の判定を二段にする

oEmbed の結果と yt-dlp の結果を組み合わせる。

| oEmbed | yt-dlp | outcome |
| --- | --- | --- |
| 200 | 成功 | `Success` |
| 200 | 失敗 | `Success`、`partial` |
| 200 | 判定不能 | `Indeterminate` |
| それ以外 | 問わず | `Failure` |

仕様書 3.3 は「oEmbed が失敗すれば 2」と書いているが、同じ節の表は直近三回で判定すると定めており、一回の失敗は 1 である。
ここでは表のほうに従い、oEmbed の失敗を `Failure` として履歴に積む。
二回続けば 2 になる。
この読み方は仕様書へ書き戻す。

同梱版との照合は、`vrchat_api/` の版と `YTDLP_VERSION` を比べ、違えば `note` に「VRChat 同梱版と不一致」を出す。
`/config` が取れなかったときは何も出さない。
照合できなかったことは、YouTube の状態ではない。

### この段で確かめること

- `dev` のログで yt-dlp の起動から終了までの秒数
- 判定不能（bot 検知）がどの程度の頻度で出るか。仕様書 7.4 が構造的に避けられないとしている事象なので、頻度だけ記録する
- `/config` の応答の形と、`YTDLP_VERSION` との一致

## 第 4 段：アラートとメトリクス

### `error/usecase.cr`

`ALERT_WEBHOOK_URL` へ JSON を POST する。
本文は `ENV`、handler 名、例外の種類、メッセージ、request id とする。

呼ぶのは handler で、`refresh` が例外を出したときに `alert` へ渡してから再送出する（仕様書 11.7）。
再送出するので、Runtime API には失敗として報告される。

同じ原因が 60 秒ごとに続くと、アラートも 60 秒ごとに届く。
最後に送った時刻をメモリに持ち、同じ例外の種類なら 10 分は送らない。
コールドスタートで忘れるが、それで一通余分に届くだけである。

webhook 自体の失敗は握りつぶしてログに残す。
アラートの失敗で本体の失敗の報告を止めない。

### 最終成功時刻のメトリクス

仕様書 9 が定める「最終成功時刻を CloudWatch のメトリクスに出す」は、CloudWatch の Embedded Metric Format で出す。
ログの一行に決まった形の JSON を書けば CloudWatch がメトリクスとして拾うので、API を呼ぶ資格情報も、実行ロールへの権限の追加も要らない。
実行ロールが持っているのはログの書き込みだけで（`infra/src/compute.ts`）、それで足りる。

`refresh` が `save_feed` まで終えたら、成功の回数を 1 として一行出す。
「5 分以上更新が無ければ通知する」は、このメトリクスが 5 分間 0 であることをアラームの条件にすれば表せる。
アラームは `infra/` の仕事なので、別の pull request にする。

## 段の外にあるもの

`.github/workflows/ytdlp-layer.yml`（仕様書 7.3）は、第 3 段で `/config` のキー名と値の形式が確かめられてから書く。
先に書くと、形式が違ったときにワークフロー側を書き直すことになる。

ワールド側の `StatusFeed` と `StatusPanel`（仕様書 8.2）は、第 1 段で実物の JSON が出始めれば、それを相手に確かめられる。
この文書の範囲には含めない。

## 仕様書へ書き戻すもの

段を進める中で決めたことのうち、仕様書に無いか、仕様書と読み方が分かれるものを挙げる。
すべての段が終わったら、まとめて #1 に反映する。

| 何 | 決めたこと | 該当する節 |
| --- | --- | --- |
| 失敗時の前回値の保持 | official にだけ当てはめる。synthetic の失敗は履歴に積み、`checked_unix` も更新する | 5.3 |
| 前回値が無い失敗 | `Unknown`、`note` は空、`checked_unix` は 0 | 5.3 |
| `State` のスキーマ版 | `v` を持ち、版が違えば履歴なしとして扱う | 6、11.4 |
| `Observation` の項目 | `partial`（成功したが一部が落ちている）を足す | 11.4 |
| YouTube の oEmbed 失敗 | `Failure` として履歴に積む。一回で 1、二回で 2 | 3.3 |
| BOOTH のお知らせの間隔 | インスタンスのメモリで数え、`State` には入れない | 3.3 |
| `services` の並び | vrchat、youtube、steam、booth、discord、cloudflare、twitch | 4 |
| handler の戻り値 | `Feed` 全体ではなく要約 | 11.7 |
| 最終成功時刻のメトリクス | Embedded Metric Format で出す | 9 |

## この文書の手元で確かめられなかったこと

BOOTH のお知らせページと VRChat の `/config` は、この文書を書いた環境からは取得できなかった。
第 2 段と第 3 段の前に、手元から一度取って固定する。

`awscr-s3` の要求がパス形式であることと、`region` に `auto` を渡して署名が通ることは、ソースを読んで判断した。
実機で通らなければ第 1 段で分かる。
