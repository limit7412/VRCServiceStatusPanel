# infra

集約サーバー（Lambda）と配信経路（R2）の定義。
仕様書は #1 にある。

AWS と Cloudflare を一つの Pulumi プログラムにまとめている。
分けないのは、片側の値をもう片側が使うためである。
R2 のバケット名も、トークンから導いた鍵も、そのまま Lambda の環境変数になる。
分けて書くと、その受け渡しを人が写すことになり、鍵を替えたときに写し忘れる。

## CI の入口はここに無い

GitHub Actions が AWS へ入るための OIDC プロバイダ、デプロイロール、実行時ロールの権限境界は、Pulumi で管理していない。
AWS CLI で作り、`docs/aws-oidc.md` に記録してある。

分けてあるのは、そこが CI の権限そのものを決める場所だからである。
同じプログラムに置くと、CI が自分を縛っている境界を書き換えられることになり、境界も入口も意味を失う。

このプログラムから見えるのは、権限境界の名前を設定 `workloadBoundaryName` で受け取ることだけである。
ARN ではなく名前なのは、ARN にアカウント ID が入り、設定ファイルを commit するからである（#26）。

## 名前の付け方

作るものはすべて `qazx7412-vrc-service-status-panel-<スタック名>-` で始める。

| 名前（stack が `dev` の場合） | 何 |
| --- | --- |
| `qazx7412-vrc-service-status-panel-dev-lambda` | 実行ロール |
| `qazx7412-vrc-service-status-panel-dev-scheduler` | Scheduler のロール |
| `qazx7412-vrc-service-status-panel-dev-refresh` | 関数、Schedule、ロググループ |
| `qazx7412-vrc-service-status-panel-dev-public` | 配信バケット |
| `qazx7412-vrc-service-status-panel-dev-state` | 内部バケット |
| `qazx7412-vrc-service-status-panel-dev-r2` | R2 のデータ用トークン |

頭を作成者の名前から始めるのは、同じ AWS / Cloudflare アカウントに置いた他のものと見分けるためである。
デプロイロールの権限もこの頭で絞ってあり、名前を外れたものへは手が届かない。

デプロイロールと権限境界だけはスタック名を挟まない。
リポジトリに対して一つあればよく、`dev` と `prod` で同じものを使う（`docs/aws-oidc.md`）。

スタック名まで含めるので、同じアカウントに dev と prod を並べても衝突しない。

**スタック名は小文字、数字、ハイフンだけ、16 文字までにする。**
Pulumi のスタック名はこれより緩く、大文字も `_` も長い名前も通るが、そのまま物理名にすると R2 は `_` を受け付けず、AWS と R2 は長さで弾く。
外れていれば `pulumi up` の最初で止まる。

いちばん厳しいのは `qazx7412-vrc-service-status-panel-<スタック名>-scheduler` で、IAM ロール名の上限 64 文字のうち頭と接尾で 44 文字を使うため 20 文字まで置ける。
16 文字にしてあるのは、関数名に余りを残すためである。

handler 名にも同じ事情がある。
関数名の上限は 64 文字で、`dev` なら 26 文字ほど残る。
外れていればこちらも `pulumi up` の最初で止まる。

Layer も同じ規則に従う（`qazx7412-vrc-service-status-panel-<スタック名>-ytdlp`）。
中身はスタックによらず同じだが、Pulumi が持つので、名前を共有すると dev と prod が同じ Layer 名へ別々に版を積むことになる。

**一度出したあとで名前を変えると、作り直しになる。**
バケットもロールも関数も、名前は置き換えでしか変えられない。
バケットには `protect: true` を付けてあるので、置き換えは削除の段階で止まる。
中身とカスタムドメインの繋ぎ先も移らない。

出したあとで変えたくなったら、次の順で行う。

1. `pulumi state unprotect` で保護を外す
2. 中身を新しいバケットへ写す
3. `pulumi up` で置き換える
4. カスタムドメインを新しいバケットへ繋ぎ直す
5. `protect: true` を戻す

配信が止まる作業である。
名前は最初に決めておくほうがよい。

## ファイルの並び

`infra/` の中身は `src/` に分けてある。
`index.ts` はそれらを繋いで出力を並べるだけである。

| ファイル | 何があるか |
| --- | --- |
| `init-stack.sh` | スタックを作って設定を入れる。設定の移行もここで起きる |
| `deploy.sh` | ビルドから `pulumi up` までをひと通り流す |
| `index.ts` | 環境変数の組み立てと出力 |
| `src/settings.ts` | スタックごとの設定 |
| `src/providers.ts` | AWS プロバイダ。R2 バックエンドとの鍵の取り合いを解く |
| `src/delivery.ts` | R2 のバケット（仕様書 6） |
| `src/credentials.ts` | R2 の S3 互換トークンと、そこから導く鍵（仕様書 9） |
| `src/functions.ts` | 関数の一覧。増やすときはここ |
| `src/roles.ts` | 実行時のロール |
| `src/compute.ts` | Lambda、ロググループ、Scheduler（仕様書 5.1） |

## 何を作るか

| 対象 | リソース | 仕様書 |
| --- | --- | --- |
| 配信バケット（既定 `qazx7412-vrc-service-status-panel-<スタック名>-public`） | `cloudflare.R2Bucket` | 6 |
| 内部バケット（既定 `qazx7412-vrc-service-status-panel-<スタック名>-state`） | `cloudflare.R2Bucket` | 6 |
| R2 の S3 互換トークン | `cloudflare.AccountToken` | 9 |
| yt-dlp と QuickJS の Layer（`qazx7412-vrc-service-status-panel-<スタック名>-ytdlp`） | `aws.lambda.LayerVersion` | 7.1、7.3 |
| 集約サーバー | `aws.lambda.Function` | 5.1 |
| ロググループと実行ロール | `aws.cloudwatch.LogGroup` / `aws.iam.Role` | — |
| 60 秒間隔の起動 | `aws.scheduler.Schedule` | 5.1 |
| 止まったことを知らせる先（`qazx7412-vrc-service-status-panel-<スタック名>-alerts`） | `aws.sns.Topic` | 9 |
| 5 分止まったら鳴るアラーム | `aws.cloudwatch.MetricAlarm` | 9 |

OIDC プロバイダ、デプロイロール、権限境界はここに無い。
CLI で作ってあり、中身は `docs/aws-oidc.md` にある。

バケット名の既定にスタック名が入るのは、同じアカウントで `dev` と `prod` を並べたときに名前がぶつかるためである。
決めた名前を使いたければ `publicBucket` と `stateBucket` で明示する。

カスタムドメインと Cache Rules は作らない。
理由はどちらも下の「手で行う作業」にある。

### 止まったことを知らせる経路

通知の経路は二つある。どちらへ届くかで、何が起きたかが分かれる。

| 経路 | 送る主体 | 何を知らせるか |
| --- | --- | --- |
| `ALERT_WEBHOOK_URL` | 関数自身（`backend/src/error/usecase.cr`） | `refresh` が例外を出した |
| SNS のトピック | CloudWatch のアラーム | 5 分のあいだ一度も配信まで終えていない |

前者は関数が上がっていることが前提である。
Layer が壊れて `bootstrap` が起動しない、Scheduler が止まる、といった場合は何も送られない。
止まったことを知らせるには、外から見ている誰かが要る。

後者の届け先を webhook にしないのも同じ理由である。
SNS から webhook へ渡すには転送する関数が要り、その関数は見張る相手と同じ足場に乗る。
メールなら AWS の中だけで完結する。

アラームは「5 分間の `RefreshSuccess` の合計が 1 未満」で鳴る。
欠測を異常として扱っている（`treatMissingData: "breaching"`）。
成功の行は成功したときにしか出ないので、関数が一度も上がっていなければ 0 が並ぶのではなくデータ点そのものが無く、既定のままでは鳴らずに `INSUFFICIENT_DATA` で止まる。

**デプロイした直後は鳴る。**
まだ一度も成功していないので、正しい振る舞いである。
最初の実行が配信まで終えれば戻る。

### R2 のデータ用トークンの権限

Pulumi が発行するトークンは、配信バケットと内部バケットの二つに絞った **Object Read & Write** である（仕様書 9）。

R2 のトークンに「書き込みのみ」の段階は無い。
選べるのは Admin Read & Write、Admin Read only、Object Read & Write、Object Read only の四つで、書けるのは Admin Read & Write と Object Read & Write の二つである。
どちらも読み取りを伴う。

その二つのうち Object 系を選ぶのは、バケット単位に絞れるためである。
Admin 系は絞れず、アカウントの R2 全体に届く。
そのかわり Admin 系は Cloudflare の REST API でも使えるのに対し、Object 系は S3 互換 API 専用で、REST API へ使うと 401 か 403 になる。
集約サーバーが要るのは S3 互換 API での読み書きだけなので、狭いほうで足りる。

読み取りはどちらにせよ要る。
内部バケットは、前回の状態を引き継ぐために毎回読む（仕様書 5.2 の手順 4）。
配信バケットの内容は CDN から誰でも読めるので、そこに読み取りが付く実害は小さい。

鍵は一組にしてある。
バケットごとに割れば片方が漏れたときの範囲は狭くなるが、どちらも同じ関数の環境変数に入るので、関数を破られたときは両方とも取られる。
分けて効くのは書き手を別の関数へ割ったときで、いまの構成にその予定は無い。

## 関数を増やすとき

関数は `src/functions.ts` の `FUNCTIONS` に並べる。
バイナリは一つで、`handler` の文字列だけが違う。
この文字列が `_HANDLER` として渡り、`backend/src/main.cr` の `Runtime::Lambda.handler` の名前と一致したものが動く。

増やすときは次の三つを揃える。

1. `src/functions.ts` の `FUNCTIONS` に足す
2. `backend/src/main.cr` に同じ名前の `handler` を足す
3. `backend/src/main.cr` の `HANDLERS` に名前を足す

名前がずれると、その関数は起動時に `UnknownHandler` で落ちる。
黙って何もしない状態にはならない。

## 用意するもの

- Pulumi CLI と Pulumi Cloud のアカウント（無料の Individual で足りる）
- AWS の資格情報（`aws configure` などで解決できる状態）
- Cloudflare の API トークン（下記）

GitHub Actions からデプロイするなら、AWS の鍵を Secrets へ置く必要はない。
OIDC のロールを CLI で作り、その ARN を Secrets へ入れる（`docs/aws-oidc.md`）。

R2 のデータ用の鍵は用意しなくてよい。
Pulumi が発行し、そのまま Lambda へ渡す。

### Cloudflare の API トークン

ダッシュボードの「My Profile → API Tokens」から作る。

**渡し方は環境変数 `CLOUDFLARE_API_TOKEN` である。**
スタックの設定には入れない。
プロバイダは設定からも環境変数からも読むが、設定へ入れると commit されるファイルに暗号文が載る。
公開する暗号文は少ないほうがよい（#24）。
CI は元からこの環境変数で渡している。

**権限ポリシー**を二つ足す。
ポリシーごとに、まず対象を選ぶドロップダウン（`アカウント全体`、`指定ドメイン` など）があり、その下で権限を選ぶ。
公式ドキュメントが Account / Zone と呼ぶ区別が、ここでは対象の選択にあたる。

| 対象 | 権限 | 何のため |
| --- | --- | --- |
| アカウント全体 | Workers R2 Storage | バケットの作成、削除、設定の変更 |
| アカウント全体 | Account API Tokens | R2 のデータ用トークンを発行する |

どれも Read と Edit（Write）の両方を入れる。
この画面は読み取りと書き込みを別々の権限として扱っており、Edit だけでは読めない。

R2 は `アカウント全体` にする。
`R2 バケット` を選ぶとバケット単位に絞れるが、それはバケットの中身を触る権限であって、バケット自体は作れない。

Cache Rules を触る権限はここに要らない。
ruleset は Pulumi の外にあり、手で置く（「手で行う作業」）。

**Account API Tokens の重さは把握しておくこと。**
これはトークンを作る権限であり、持たせた相手はアカウント内の任意の権限を持つトークンを発行できる。
実質的に管理者相当である。
R2 のデータ用トークンを Pulumi に発行させる以上は避けられないが、[IP 制限や TTL](https://developers.cloudflare.com/fundamentals/api/how-to/restrict-tokens/) で使える範囲を狭められる。

## 状態の置き場所

Pulumi Cloud に置く（#23）。

置き場所は `Pulumi.yaml` の `backend.url` で固定してある。

```yaml
backend:
  url: https://api.pulumi.com
```

ここで固定するのは、バックエンドがスタックより先に決まるためである。
`Pulumi.<スタック名>.yaml` の設定はバックエンドが決まってからでないと読めないので、置き場所を書く先にはならない。

**`pulumi login` の先より、ここが優先される。**
別の場所へログインしていても、このプロジェクトを流すかぎり Pulumi Cloud へ向かう。
Pulumi CLI 3.259.0 で、`pulumi login file://...` したあとに `pulumi stack ls` がそちらを見に行かないことを確かめた。
`backend.url` を書かないプロジェクトでは、ログイン先がそのまま使われる。

**ただし環境変数 `PULUMI_BACKEND_URL` はこれを上書きする。**
同じ確認で、`PULUMI_BACKEND_URL` を渡すと `backend.url` を無視して指した先が使われた。
意図せず別の state を触らないよう、この変数はシェルに残さないこと。

ここを消すと、手元のログイン先しだいで別のバックエンドへ出てしまう。
fork した人が file バックエンドのまま流すこともできてしまう。

**手元では `pulumi login` する。**

```
pulumi login
```

ブラウザが開いてトークンを受け取る。
以後は資格情報がローカルに残るので、デプロイのたびに繰り返す必要はない。

CI はトークンを持たない。
GitHub Actions の OIDC を Pulumi Cloud のアクセストークンへ交換する（「ワークフローでの受け取り」）。
長い寿命の鍵が Secrets に増えないのがこの方式を採った理由である。

**fork して自分のアカウントへ出すときは、`pulumi login` した先が自分の組織になっていればよい。**
以前は `backend.url` に作者のバケットとアカウント ID が入っていたので、そこを書き換えないと作者のアカウントへ繋ぎに行っていた。
いまはその一歩が消えている。

CI からも流すなら、書き換える先が二つある。

一つは AWS 側で、`docs/aws-oidc.md` のロールと境界を自分のアカウントに作り直す。
信頼ポリシーの `sub` は元のリポジトリを指しているので、fork の Actions ではそのままロールを引けない。

もう一つは Pulumi Cloud 側で、ワークフローの `pulumi/auth-actions` に渡す `organization` と `scope` を自分のものにする（「ワークフローでの受け取り」）。
自分の組織に OIDC issuer を登録しても、要求するトークンが作者のものを指したままでは交換が通らない。

**state の中の secret は預けない。**
`--secrets-provider passphrase` を続けるので、Pulumi Cloud にあるのは `PULUMI_CONFIG_PASSPHRASE` で暗号化した暗号文だけである。
Pulumi Cloud の鍵管理には切り替えない。
パスフレーズを無くすと state を読めなくなるのは、置き場所を変えても同じである。
控えておくこと。

**スタックを手で作るなら `--secrets-provider passphrase` を省かないこと。**
Pulumi Cloud での既定はサービス側の鍵管理であり、DIY バックエンドのころの既定（passphrase）とは違う。
`PULUMI_CONFIG_PASSPHRASE` を渡しても provider は切り替わらないので、省くと secret の鍵まで預けることになる。
`init-stack.sh` は `stack select --create` に付けて渡している。

**`src/delivery.ts` が作る内部バケットは state とは別物である。**
`qazx7412-vrc-service-status-panel-<スタック名>-state` のほうは集約サーバーが使うもので（仕様書 6）、Pulumi が管理する。
名前に `state` が入っているのは、集約サーバーが合成監視の履歴と前回値を置く先だからで、Pulumi の state とは関係が無い。

### パスフレーズの作り方

**覚えずに作る。**
生成してパスワードマネージャへ入れる。

```
openssl rand -base64 32
```

`init-stack.sh` は 32 文字未満を受け付けない。
`openssl rand -base64 32` の出力は 44 文字なので、そのまま通る。

数えるのは文字であってバイトではない。
バイトで数えると、同じ絵文字を 8 個並べただけの値も 32 バイトあり、覚えられる長さのものが通ってしまう。
`${#phrase}` を使わないのは、その単位がロケールで変わるためである（#35）。
UTF-8 の継続バイトを落とした残りを数えるので、どのロケールでも同じ判定になる。

理由は commit する先が public だからである（#24）。
`Pulumi.<スタック名>.yaml` には secret が暗号文として入り、そのファイルは commit する。
暗号文が公開される以上、総当たりは誰でも好きなだけ試せる。

Pulumi の鍵導出は PBKDF2-SHA256 を 100 万回まわして AES-256-GCM の鍵を作る。
一回の試行が重いので、生成した値なら手が出ない。
一方、人が思いついて覚えられる範囲の文字列は、それでも辞書と規則の射程に入る。

文字種の規則は置いていない。
規則を足すほど、生成した値が落ちて人が考えた値が通る、という逆転が起きるためである。
長さだけを見る。

### AWS の資格情報

`AWS_*` をそのまま使う。
`aws configure` のプロファイルも普通に使える。

かつては AWS 側の鍵を `DEPLOY_AWS_*` で渡し、`src/providers.ts` が `envVarMappings` で写していた。
state を R2 へ置いていたころ、そのバックエンドが `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` から R2 の鍵を読むため、AWS の操作と食い違ったからである。
state が Pulumi Cloud へ移ってバックエンドがこの変数を見なくなったので、切り分けも写し替えも要らなくなった（#23）。

## 設定の置き場所

スタックごとの値は `Pulumi.<スタック名>.yaml` に入る。
**このファイルは commit する。**

`pulumi config set --secret` で入れた値は暗号文として記録される。
復号の鍵はパスフレーズから導く。
**このリポジトリは public なので、暗号文もそのまま公開される。**
強度は「パスフレーズの作り方」に書いた条件で担保する。
弱いパスフレーズなら、持たない相手でも総当たりで導ける（#24）。

```yaml
config:
  vrc-service-status-panel:cloudflareAccountId: 023e105f4ecef8ad9ca31a8372d0c353
  vrc-service-status-panel:alertWebhookUrl:
    secure: v1:zXQ8kR2mN4pL:vT7hJ...
```

平文で入るのは識別子のほうである。
アカウント ID、ゾーン ID、配信ホスト名、バケット名、yt-dlp の版。

commit するのは、CI へ渡すものを減らすためである。
ファイルを持たせない道もあるが、その場合は値を GitHub の Secrets と Variables へ並べ直すことになり、設定を足すたびにワークフローも直すことになる。
ずれても `pulumi up` が落ちて初めて気づく。
commit してあれば、CI へ渡すのは鍵と資格情報だけで済む。

**このリポジトリは public である。**
平文の識別子は読まれる前提で置いてある。

置いたままにできるのは、どれも識別子であって資格情報ではないためである。
OIDC のロールは `sub` で引ける相手を絞ってあるので、AWS のアカウント ID を知られてもロールを引けるようにはならない。
ただしロール名は推測できるようになる。
Cloudflare のアカウント ID とゾーン ID も、トークンと組にならなければ何もできない。

暗号文のほうは「パスフレーズの作り方」の条件で守る（#24）。

`Pulumi.example.yaml` は残してある。
fork して自分のアカウントへ出すときは、こちらを写す。
commit されているほうには作者のアカウント ID と、作者のパスフレーズで暗号化された値が入っている。

## デプロイ

`infra/deploy.sh` がひと通り流す。

```
printf 'CLOUDFLARE_API_TOKEN: '; read -rs cloudflare_token && echo

CLOUDFLARE_API_TOKEN="$cloudflare_token" infra/deploy.sh
CLOUDFLARE_API_TOKEN="$cloudflare_token" infra/deploy.sh --ytdlp 2025.09.26
```

`CLOUDFLARE_API_TOKEN` はスタックの設定に入らないので、流すときに渡す（#24）。
`deploy.sh` は最初に見て、無ければそこで止まる。

**`CLOUDFLARE_API_TOKEN` は export しない。**
export すると、デプロイが終わったあとも呼び出し元のシェルに残り、そこで動かすものすべてへ引き継がれる。
この呼び出しにだけ渡せば、そこで終わる。

`deploy.sh` の側でも、受け取ったらすぐ環境から外し、`pulumi up` へ渡すときだけ戻している。
渡ってきたまま進むと、`npm ci` が動かす依存パッケージのインストールスクリプトや、`build.sh` が起こす docker まで、このトークンを見られることになる。
「Account API Tokens の重さ」で書いたとおり実質的に管理者相当なので、Pulumi と無関係なコードへは渡さない。

`PULUMI_CONFIG_PASSPHRASE` のほうは export する。
渡す先が一つではなく、`init-stack.sh` も `deploy.sh` も中で `pulumi` を何度も呼ぶためである。

### この変更より前に作ったスタック

**状態の置き場所が R2 から Pulumi Cloud へ変わった（#23）。**
R2 に state を持つスタックは、`pulumi login` した先から見えない。
移送するなら、古い `backend.url` を指した作業ツリーで `pulumi stack export` して `pulumi stack import` で入れ直すことになる。

このリポジトリではその手間は要らない。
`Pulumi.<スタック名>.yaml` はまだ commit されておらず（#12）、`pulumi up` も流れていないので、移す state が無い。

`deploy.sh` の前に `init-stack.sh` を流し直す。

設定から `cloudflare:apiToken` を落とすのも、`ytdlpLayerArn` を落として `ytdlpLayerVersion` を `ytdlpVersion` へ引き継ぐのも、`workloadBoundaryArn` を `workloadBoundaryName` へ移すのも、短いパスフレーズの入れ替えを案内するのも `init-stack.sh` の中にある。
`deploy.sh` だけを流すと、設定ファイルにトークンの暗号文が残り、アカウント ID も入ったままになる。

```
printf 'PULUMI_CONFIG_PASSPHRASE: '; read -rs PULUMI_CONFIG_PASSPHRASE && echo
export PULUMI_CONFIG_PASSPHRASE

infra/init-stack.sh dev
```

聞かれる値には、いま入っているものが既定として出る。
Enter で通せばそのまま残る。

`--ytdlp` は `ytdlpVersion` を書き換えるだけである。
Layer そのものは Pulumi が持つので、発行と関数への反映は同じ `pulumi up` の中で揃う（#8）。

Layer の zip は毎回用意される。
`backend/layer/build.sh` は同じ版の zip が既にあれば何もしないので、36 MiB を取り直すのは版を変えたときだけである。

`--ytdlp` 以外の引数はそのまま `pulumi up` へ渡る（`--yes` など）。

commit はしない。
設定が変わったら `Pulumi.<スタック名>.yaml` を自分で残す。

### 初回にすること

`deploy.sh` は設定が埋まっている前提で動く。
設定は `infra/init-stack.sh` が作る。

```
cd infra
npm ci

# 状態は Pulumi Cloud にある。初回だけログインする（#23）
pulumi login

# パスフレーズは覚えずに作る（「パスフレーズの作り方」を参照）。
#   openssl rand -base64 32
# 値を export の右辺に書かない。シェルの履歴に平文で残り、
# commit 済みの設定ファイルと合わされば alertWebhookUrl を復号できてしまう
# read の -p は zsh では別の意味になるので、プロンプトは printf で出す
printf 'PULUMI_CONFIG_PASSPHRASE: '
read -rs PULUMI_CONFIG_PASSPHRASE && echo
export PULUMI_CONFIG_PASSPHRASE

./init-stack.sh dev
```

ファイルに置いてある場合は `PULUMI_CONFIG_PASSPHRASE_FILE` にその場所を渡してもよい。

二度目以降に流すと、いま入っている値を既定として見せる。
Enter で通せばそのまま残る。
秘密の値は見せずに「Enter で今の値のまま」と聞く。
空で答えても消えないので、消したいときは `pulumi config rm` を使う。

値は一つずつ聞かれる。
省略できるものは空のまま Enter で飛ばせる。
秘密の値は標準入力から渡すので、コマンドラインにも履歴にも残らない。
何を聞かれるかは `Pulumi.example.yaml` に並べてある。

出来上がった `Pulumi.dev.yaml` は commit する（#12）。
続きはスクリプトが最後に案内する。

```
git add Pulumi.dev.yaml

printf 'CLOUDFLARE_API_TOKEN: '; read -rs cloudflare_token && echo
CLOUDFLARE_API_TOKEN="$cloudflare_token" ./deploy.sh
```

トークンを export せずにこの呼び出しへだけ渡すのは「デプロイ」に書いたとおりである。

Layer は `deploy.sh` の中の `pulumi up` が作る。
版は `init-stack.sh` で入れた `ytdlpVersion` を使うので、初回でも `--ytdlp` は要らない。
あとから版を変えるときだけ渡す。

```
CLOUDFLARE_API_TOKEN="$cloudflare_token" ./deploy.sh --ytdlp 2025.09.26
```

#### GitHub Actions からも流す場合

権限境界の ARN が要る。
入れないと実行ロールに境界が付かず、手元からは通っても CI からは `CreateRole` で止まる。

`init-stack.sh` が「GitHub Actions からの入口」で聞く。
いま繋がっている AWS アカウントに境界が実在するときだけ既定として出るので、Enter で通せば入る。
飛ばしていたら後から足す。

```
pulumi config set --stack dev workloadBoundaryName \
  qazx7412-vrc-service-status-panel-workload-boundary

git add Pulumi.dev.yaml
```

Secrets へ登録するものは「ワークフローでの受け取り」にある。

### スクリプトが何をしているか

手で並べると次の三つになる。
詰まったときはこの順で追う。

**どれも `infra/` から実行する。**
3 が `Pulumi.yaml` を要るためで、そのぶん 1 と 2 は `../backend/...` を指す。

```
cd infra

# トークンは export せずにこの三つへ渡す（「デプロイ」を参照）
printf 'CLOUDFLARE_API_TOKEN: '; read -rs cloudflare_token && echo

# 1. バイナリを作る（docker が要る）
../backend/build.sh

# 2. Layer の zip を用意する（仕様書 7.1、7.3）
#    版は ytdlpVersion と揃える。揃っていないと、実行時の比較が
#    載せた版ではなく設定の版を見ることになる。
../backend/layer/build.sh "$(pulumi config get ytdlpVersion)" "" ../backend/ytdlp-layer.zip

# 3. 反映する
CLOUDFLARE_API_TOKEN="$cloudflare_token" pulumi up
```

`pulumi up` は `../backend/bootstrap.zip` と `../backend/ytdlp-layer.zip` を読むので、1 か 2 を飛ばすとそこで止まる。

Layer の発行は 3 の中で起きる。
zip が前回と同じなら新しい版は作られない。

OIDC のロールと権限境界はこのスクリプトの対象外である。
あちらは CI の権限そのものを決める場所で、Pulumi に載せていない（「GitHub Actions から AWS へ入る」を参照）。

## GitHub Actions から AWS へ入る

入口は Pulumi に無い。
OIDC プロバイダ、デプロイロール、実行時ロールの権限境界は AWS CLI で作ってあり、権限の一覧も作り直す手順も `docs/aws-oidc.md` にある。
長い寿命の鍵を Secrets へ置かずに済む。

ロールはリポジトリに対して一つで、`dev` と `prod` で同じものを使う。
引けるのは既定で `master` への push に限る。

### 本体へ渡すもの

境界の名前を設定に入れる。
ARN は `src/roles.ts` がその場のアカウントから組む。

```
pulumi config set workloadBoundaryName \
  qazx7412-vrc-service-status-panel-workload-boundary
```

これを入れないと、実行ロールに境界が付かない。
手元から流す分にはそれでも通るが、CI からは通らない。
デプロイロールは境界の付いたロールしか作れず、`CreateRole` がそこで止まる。

ロールの ARN は GitHub の Secrets に `AWS_DEPLOY_ROLE_ARN` として登録する。

### ワークフローでの受け取り

CI はトークンを一つも持たずに Pulumi Cloud へ入る。
`pulumi/auth-actions` が GitHub Actions の OIDC トークンをアクセストークンへ交換し、以降のステップから見える `PULUMI_ACCESS_TOKEN` に入れる。

AWS 側も OIDC で入る。
`AWS_*` の取り合いはもう起きないので、`configure-aws-credentials` にはジョブの環境へ普通に書かせてよい。

**スタック名は組織で修飾する。**
素の `prod` は、そのランナーの既定の組織のスタックとして解決される。
手元で `pulumi org set-default` を済ませてあっても、CI の既定はそれと違う組織になりうる。
OIDC で交換したトークンで `pulumi stack ls` を打つと `limit7412/dev` と修飾して出るのに、
`--stack dev` は `no stack named 'dev' found` で止まった（#41）。

**資格情報を出す前に `npm ci` を済ませる。**
どちらのアクションも、以降のステップから見える環境変数に資格情報を置く。
`npm ci` をあとに回すと、依存パッケージのインストールスクリプトからデプロイロールの一時資格情報と `PULUMI_ACCESS_TOKEN` が読める。
手元の `deploy.sh` が Cloudflare のトークンを `npm ci` の前で外しているのと同じ理由である。
Pulumi CLI を入れる `pulumi/actions` も資格情報を要らないので、先へ寄せてある。

```yaml
permissions:
  id-token: write   # OIDC のトークンを発行させる。既定では付かない
  contents: read

# スタック名を修飾する組織。pulumi/auth-actions へ渡すものと同じ値にする
env:
  ORG: limit7412

steps:
  - uses: actions/checkout@v7

  # bootstrap.zip は .gitignore の対象で、checkout には入っていない。
  # src/compute.ts が FileArchive として即座に開くため、無いと
  # pulumi up は AWS へ触る前にファイル未検出で止まる。
  #
  # build.sh は linux/arm64 のイメージを走らせる。x86_64 のランナーでは
  # binfmt の登録が要る。
  - uses: docker/setup-qemu-action@v3
    with:
      platforms: arm64
  - run: backend/build.sh

  # 依存の取得は資格情報を出す前に済ませる。
  # あとに回すと、install スクリプトから AWS と Pulumi Cloud の資格情報が読める
  - run: npm ci
    working-directory: infra

  # Pulumi CLI はランナーに入っていない。
  # このアクションは command を渡さなければ CLI を入れるだけで終わる。
  # get.pulumi.com のスクリプトで入れてもよい
  - uses: pulumi/actions@v6

  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
      aws-region: ap-northeast-1

  # Pulumi Cloud へは OIDC で入る。PULUMI_ACCESS_TOKEN を Secrets へ置かない。
  # 無料の Individual で使えるのは personal トークンだけである。
  # organization は個人アカウントでも必須で、値は自分のユーザー名になる。
  # fork するならこの二つを自分のものに書き換える
  - uses: pulumi/auth-actions@v2
    with:
      organization: limit7412
      requested-token-type: urn:pulumi:token-type:access_token:personal
      scope: user:limit7412

  # Layer の zip も .gitignore の対象で、checkout には入っていない。
  # src/layer.ts が FileArchive として開くので、bootstrap.zip と同じく
  # 無いと pulumi up はファイル未検出で止まる。
  #
  # 版は流す相手のスタックから読む。ここで別のスタックの版を渡すと、
  # 中身と description と YTDLP_VERSION が食い違う。
  # config get は Pulumi CLI と Pulumi Cloud への資格情報を要るので、
  # このステップは pulumi/actions と auth-actions の後に置く。
  - run: |
      backend/layer/build.sh \
        "$(pulumi -C infra config get --stack "$ORG/prod" ytdlpVersion)" \
        "" backend/ytdlp-layer.zip
    env:
      PULUMI_CONFIG_PASSPHRASE: ${{ secrets.PULUMI_CONFIG_PASSPHRASE }}

  # スタック名は commit してある Pulumi.<スタック名>.yaml のものにする
  - run: pulumi up --yes --stack "$ORG/prod"
    working-directory: infra
    env:
      # 設定は checkout した Pulumi.prod.yaml から読まれる。
      # 暗号文で入っている値を開けるのに要る（「設定の置き場所」を参照）
      PULUMI_CONFIG_PASSPHRASE: ${{ secrets.PULUMI_CONFIG_PASSPHRASE }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

Secrets に置くのは三つだけである。

| 名前 | 何に使う |
| --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | 引くロールを指す（`docs/aws-oidc.md`） |
| `PULUMI_CONFIG_PASSPHRASE` | `Pulumi.<スタック名>.yaml` の暗号文を開ける |
| `CLOUDFLARE_API_TOKEN` | Cloudflare プロバイダ |

**Pulumi Cloud 側の下ごしらえが一つ要る。**
GitHub Actions を OIDC issuer として登録する。
登録しないと `pulumi/auth-actions` の交換が通らない。
手順は[公式の案内](https://www.pulumi.com/docs/administration/access-identity/oidc-issuers/github/)にある。

**この例は `prod` を更新する。**
動かすには `prod` のスタックを作り、その `Pulumi.prod.yaml` を commit しておく必要がある。
デプロイロールは `dev` と `prod` のどちらにも届くので、ロールの側で用意するものは無い。

Layer を Pulumi に持たせたことで、デプロイロールには Layer の発行と削除も要る。
読み取りだけのままだと、最初の `PublishLayerVersion` で `AccessDenied` になる。
`docs/aws-oidc.md` のポリシーには入れてあり、実物のロールにも反映済みである。
ロールは CI から更新できない設計なので、権限を変えるときは手元から CLI で流す。

`pulumi login` のステップも、`pulumi config set` を並べるステップも要らない。
置き場所は `Pulumi.yaml` に、設定は `Pulumi.<スタック名>.yaml` にあり、どちらも checkout した時点でそろっている。
**そろっていないのはバイナリだけ**で、これは `.gitignore` の対象なので毎回作る。

Layer の zip もバイナリと同じ扱いになる。
どちらも `.gitignore` の対象なので、`pulumi up` の前に作る（仕様書 7.1、7.3）。
発行そのものは `pulumi up` の中で起きるので、デプロイロールには Layer の発行と削除も与えてある。

実体は `.github/workflows/deploy.yml` にある。
上の並びをそのまま書いたものである。

**手で起動したときだけ動く。**
`master` への push では出さない。
まだ一度もデプロイしていないので、押した覚えのない更新が走るほうが害が大きい。
常時デプロイへ変えるなら `push: branches: [master]` を足す。

出す先のスタックは起動時に選ぶ。
既定は `dev` である。

### ロールの権限

`docs/aws-oidc.md` に一覧がある。
名前の頭で絞ってあり、同じアカウントの他のリソースへは届かない。
このロール自身の権限を書き換える操作は Deny してあるので、CI からは変えられない。

実行ロールに付く権限境界も同じ文書にある。
`src/roles.ts` は設定の `workloadBoundaryName` から ARN を組んで渡すだけで、境界そのものはここに無い。

## 手で行う作業

**Pulumi Cloud に GitHub Actions を OIDC issuer として登録する。**
CI からデプロイする場合だけ要る。
登録しないと `pulumi/auth-actions` の交換が通らず、ワークフローが Pulumi Cloud へ入れない。

手元から流すだけなら要らない。
`pulumi login` で足りる。

CLI にこれを行うコマンドは無い。
コンソールか REST API のどちらかになる（Pulumi CLI 3.259.0 の `pulumi org` に issuer を扱うサブコマンドが無いことを確かめた）。

コンソールなら Settings → Access Management → OIDC Issuers → Register issuer。
四つ聞かれるが、必須は Name と URL だけである。

| 欄 | 値 |
| --- | --- |
| Name | `github-actions` |
| URL | `https://token.actions.githubusercontent.com` |
| Max expiration (seconds) | `3600` |
| Thumbprint | 空のまま |

**Max expiration** は、交換して渡すアクセストークンの寿命の上限である。
`pulumi/auth-actions` の `token-expiration` はあくまで要求で、そのまま通すか短く切り詰めるかは発行する側が決める。
いまのワークフロー例はその入力を渡していないので空でも動くが、あとで長い寿命を要求する行が足されたときに、ここで頭打ちにできる。
このプロジェクトのデプロイは 1 時間もあれば収まる。

**Thumbprint** は、発行者の TLS 証明書を検証するための SHA-1 の指紋である。
空のままにする。
空なら Pulumi が発行者の URL から鍵の集合（**JWKS**、JSON Web Key Set）を取りに行き、指紋も自分で持つ。

手で埋めると、GitHub が TLS 証明書を更新するたびにこちらで入れ替えることになり、忘れれば交換が通らなくなる。
入れ替え自体は `regenerate-thumbprints` で取り直せるので手はある。
それでも、追随する仕事を自分で抱える理由が無い。
AWS の OIDC プロバイダに指紋を渡していないのと同じ理由である（`docs/aws-oidc.md`）。

続けて認可ポリシーを足す。
無料の Individual で使えるのは personal トークンだけで、ワークフローの `pulumi/auth-actions` に渡す値と揃える必要がある。

登録した直後は、どのトークン交換も拒む Deny のポリシーが一つだけ入っている。
足すのではなく、これを差し替える形になる。

Subject 違いで二つ要る。
他の欄はどちらも同じである。

| 項目 | 値 |
| --- | --- |
| Decision | Allow |
| Token type | Personal |
| Scope | `user:limit7412` |
| Audience | `urn:pulumi:org:limit7412` |
| Subject（新しい形） | `repo:limit7412@19320218/VRCServiceStatusPanel@1346007387:ref:refs/heads/master` |
| Subject（古い形） | `repo:limit7412/VRCServiceStatusPanel:ref:refs/heads/master` |

**Subject が二つあるのは、GitHub がこの claim の形を移しているためである。**
いま届くトークンは、所有者とリポジトリの数値 ID を含む新しい形である。
事情は `docs/aws-oidc.md` の「誰がロールを引けるか」にある。
数値 ID は `gh api /repos/<owner>/<repo> --jq '"\(.owner.id) \(.id)"'` で引ける。

**Subject は `:*` で終わらせない。**
公式の例は `repo:<owner>/<repo>:*` だが、それだとそのリポジトリのどのブランチ、どの PR のワークフローからでもトークンを引ける。
AWS 側の信頼ポリシーも `master` の ref で動くワークフローに絞ってあるので、ここも揃える（`docs/aws-oidc.md` の「誰がロールを引けるか」）。
`sub` はイベントの種別を持たないため、どちらも push だけには絞れない。
`master` 上の `workflow_dispatch` も同じ値になる。

REST API で行うなら三つを順に叩く。
`<orgName>` は個人アカウントならユーザー名である。
`Authorization: token <アクセストークン>` を付ける。

```
POST  /api/orgs/<orgName>/oidc/issuers
GET   /api/orgs/<orgName>/auth/policies/oidcissuers/<issuerId>
PATCH /api/orgs/<orgName>/auth/policies/<policyId>
```

`POST` の body は `{"name": ..., "url": ..., "maxExpiration": 3600}` である。
返る `id` が `<issuerId>` になる。
ここに `policies` を並べても入らない。ポリシーは次の二つで差し替える。

`GET` は登録時に入った Deny のポリシーを、それが属する `<policyId>` ごと返す。
`PATCH` の body は `{"policies": [...]}` で、送った配列がそのまま置き換わる。
一つの要素は次の形になる。

```json
{
  "decision": "allow",
  "tokenType": "personal",
  "userLogin": "limit7412",
  "authorizedPermissions": null,
  "rules": {
    "aud": "urn:pulumi:org:limit7412",
    "sub": "repo:limit7412@19320218/VRCServiceStatusPanel@1346007387:ref:refs/heads/master"
  }
}
```

`authorizedPermissions` は組織トークン向けの項目なので、personal では渡さない。

**`GET` が返した Deny をそのまま送り返さない。**
あれは `sub` が空文字であり、`PATCH` は空の `sub` を弾く
（`key sub should at least have a strict matching portion`）。
差し替えるときは Allow だけを並べる。
並べなかった交換は、どのみち通らない。

fork するなら、この表の `limit7412` と `limit7412/VRCServiceStatusPanel` を自分のものに書き換える。
ワークフロー側の `organization` と `scope` も同じ値にする。

**カスタムドメインの接続。**
ダッシュボードで配信バケットに配信ホスト名を繋ぐ。
R2 → バケットを選ぶ → Settings → Custom Domains → Add。

繋ぐ先のバケット名は `pulumi stack output publicBucketOut` で確かめる。
既定のままなら `qazx7412-vrc-service-status-panel-<スタック名>-public` である。
`publicBucket` を設定している場合はその名前になる。

Pulumi に載せていないのは、`cloudflare_r2_custom_domain` に、作成の約一分後に `enabled` が `false` へ戻る不具合があるためである（[cloudflare/terraform-provider-cloudflare#6578](https://github.com/cloudflare/terraform-provider-cloudflare/issues/6578)）。
Pulumi の Cloudflare プロバイダは同じ Terraform プロバイダを包んだものなので、同じ挙動になる。
配信そのものが止まる箇所であり、載せる利より害が大きい。

不具合が直れば `src/delivery.ts` に `R2CustomDomain` を足すだけで済む。

**Cache Rules を置く。**
配信 JSON は `.json` なので、既定ではキャッシュの対象に入らない（仕様書 6）。
ゾーンの Cache Rules で、配信ホストの `/v1/` 以下を対象へ入れる。

ダッシュボードなら Caching → Cache Rules → Create rule。
API なら entrypoint をまとめて置き換える。

```
curl -X PUT \
  -H "Authorization: Bearer $cloudflare_token" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/<ゾーンID>/rulesets/phases/http_request_cache_settings/entrypoint" \
  -d @rules.json
```

**すべてのスタックの配信ホストを、この一つの ruleset に並べる。**
`http_request_cache_settings` の `kind: "zone"` の ruleset は、ゾーンに一つしか置けない。
`dev` と `prod` は同じゾーンへ配信するので、スタックごとに持つことはできない（#45）。

```json
{
  "rules": [
    {
      "ref": "cache_status_feed",
      "description": "v1 以下をキャッシュし、TTL はオブジェクトに従う",
      "expression": "(http.host in {\"vrc-status.oxymoron.link\" \"vrc-status-dev.oxymoron.link\"} and starts_with(http.request.uri.path, \"/v1/\"))",
      "action": "set_cache_settings",
      "action_parameters": {
        "cache": true,
        "edge_ttl": { "mode": "respect_origin" },
        "browser_ttl": { "mode": "respect_origin" }
      }
    }
  ]
}
```

`PUT` は ruleset の中身を丸ごと置き換える。
このゾーンで他の Cache Rules も使っているなら、先に entrypoint を読んで、
残す規則ごと並べ直す。

```
curl -H "Authorization: Bearer $cloudflare_token" \
  "https://api.cloudflare.com/client/v4/zones/<ゾーンID>/rulesets/phases/http_request_cache_settings/entrypoint"
```

`edge_ttl` は `respect_origin` にする。
仕様書 6 の「オブジェクトの `Cache-Control` に従い 30 秒」がこれにあたる。
`override_origin` で 30 秒を書くことはできない。
Edge Cache TTL の下限が Free で 2 時間、Pro で 1 時間あり、Business 以上でないと 30 秒を指定できない。

触るトークンには、アカウント全体の `Account Rulesets` と、配信ドメインの `Cache Settings` が要る。
どちらも Read と Edit を入れる。
**「Cache Rules」という項目は無い。** 権限の一覧では `Cache Settings` という名前で並んでいる。

Pulumi に載せていないのは、ゾーンに一つしか置けない共有資源だからである。
スタックを増やすたびに取り合いになり、`pulumi destroy` の射程に入れると、
片方のスタックを畳んだだけでもう片方の配信のキャッシュ設定まで消える。
AWS の OIDC プロバイダを Pulumi に載せていないのと同じ形にしてある（`docs/aws-oidc.md`）。

**SNS のトピックに届け先を足す。**
`pulumi up` が作るのはトピックとアラームだけで、届け先は入っていない。
足すまでは、アラームが鳴っても誰にも届かない。

```
aws sns subscribe \
  --topic-arn "$(pulumi stack output alertTopicArn)" \
  --protocol email --notification-endpoint <アドレス>
```

送ったあと、AWS からそのアドレスへ確認のメールが届く。
中のリンクを開くまで購読は `PendingConfirmation` のままで、その間は何も届かない。

```
aws sns list-subscriptions-by-topic \
  --topic-arn "$(pulumi stack output alertTopicArn)" \
  --query 'Subscriptions[].[Protocol,Endpoint,SubscriptionArn]' --output table
```

`SubscriptionArn` が `PendingConfirmation` のままなら、まだ確認していない。

**届け先を設定に持たせていないのは、その値が commit されるためである。**
このリポジトリは public なので（仕様書 9）、メールアドレスを設定へ置けばそのまま公開される。
secret にすれば暗号文になるが、そうすると値が Output になり、
「設定してあれば購読を作る」という条件そのものが書けなくなる。

手作業が増えるわけでもない。
上のとおり、確認のリンクを開くところはどのみち人の手が要る。
Chatbot 経由の Slack のように、メール以外へ届けたい場合の余地も残る。

**デプロイロールに SNS とアラームの権限を足す。**
CI からデプロイする場合だけ要る。
ロールは Pulumi の外にあり、CLI で作ってある（`docs/aws-oidc.md`）。
`Alerts` と `Alarms` の二つの Sid が入っていないと、最初の `sns:CreateTopic` で止まる。

## 確かめ方

```
npm run typecheck   # tsc --noEmit
pulumi preview      # 差分を見る
```

