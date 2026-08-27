# infra

集約サーバー（Lambda）と配信経路（R2）の定義。仕様書は #1 にある。

AWS と Cloudflare を一つの Pulumi プログラムにまとめている。
分けないのは、片側の値をもう片側が使うためである。
R2 のバケット名も、トークンから導いた鍵も、そのまま Lambda の環境変数になる。
分けて書くと、その受け渡しを人が写すことになり、鍵を替えたときに写し忘れる。

## CI の入口はここに無い

GitHub Actions が AWS へ入るための OIDC プロバイダ、デプロイロール、実行時ロールの
権限境界は、Pulumi で管理していない。AWS CLI で作り、`docs/aws-oidc.md` に記録してある。

分けてあるのは、そこが CI の権限そのものを決める場所だからである。
同じプログラムに置くと、CI が自分を縛っている境界を書き換えられることになり、
境界も入口も意味を失う。

このプログラムから見えるのは、権限境界の ARN を設定 `workloadBoundaryArn` で
受け取ることだけである。

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

頭を作成者の名前から始めるのは、同じ AWS / Cloudflare アカウントに置いた
他のものと見分けるためである。デプロイロールの権限もこの頭で絞ってあり、
名前を外れたものへは手が届かない。

デプロイロールと権限境界だけはスタック名を挟まない。リポジトリに対して一つあればよく、
`dev` と `prod` で同じものを使う（`docs/aws-oidc.md`）。

スタック名まで含めるので、同じアカウントに dev と prod を並べても衝突しない。

**スタック名は小文字、数字、ハイフンだけ、16 文字までにする。** Pulumi のスタック名は
これより緩く、大文字も `_` も長い名前も通るが、そのまま物理名にすると R2 は `_` を
受け付けず、AWS と R2 は長さで弾く。外れていれば `pulumi up` の最初で止まる。

いちばん厳しいのは `qazx7412-vrc-service-status-panel-<スタック名>-scheduler` で、
IAM ロール名の上限 64 文字のうち頭と接尾で 44 文字を使うため 20 文字まで置ける。
16 文字にしてあるのは、関数名に余りを残すためである。

handler 名にも同じ事情がある。関数名の上限は 64 文字で、`dev` なら 26 文字ほど残る。
外れていればこちらも `pulumi up` の最初で止まる。

Layer も同じ規則に従う（`qazx7412-vrc-service-status-panel-<スタック名>-ytdlp`）。
中身はスタックによらず同じだが、Pulumi が持つので、名前を共有すると dev と prod が
同じ Layer 名へ別々に版を積むことになる。

**一度出したあとで名前を変えると、作り直しになる。** バケットもロールも関数も、
名前は置き換えでしか変えられない。バケットには `protect: true` を付けてあるので、
置き換えは削除の段階で止まる。中身とカスタムドメインの繋ぎ先も移らない。

出したあとで変えたくなったら、次の順で行う。

1. `pulumi state unprotect` で保護を外す
2. 中身を新しいバケットへ写す
3. `pulumi up` で置き換える
4. カスタムドメインを新しいバケットへ繋ぎ直す
5. `protect: true` を戻す

配信が止まる作業である。名前は最初に決めておくほうがよい。

## ファイルの並び

`infra/` の中身は `src/` に分けてある。`index.ts` はそれらを繋いで
出力を並べるだけである。

| ファイル | 何があるか |
| --- | --- |
| `init-stack.sh` | スタックを作って設定を入れる。設定の移行もここで起きる |
| `deploy.sh` | ビルドから `pulumi up` までをひと通り流す |
| `index.ts` | 環境変数の組み立てと出力 |
| `src/settings.ts` | スタックごとの設定 |
| `src/providers.ts` | AWS プロバイダ。R2 バックエンドとの鍵の取り合いを解く |
| `src/delivery.ts` | R2 のバケットと Cache Rules（仕様書 6） |
| `src/credentials.ts` | R2 の S3 互換トークンと、そこから導く鍵（仕様書 9） |
| `src/functions.ts` | 関数の一覧。増やすときはここ |
| `src/roles.ts` | 実行時のロール |
| `src/compute.ts` | Lambda、ロググループ、Scheduler（仕様書 5.1） |

## 何を作るか

| 対象 | リソース | 仕様書 |
| --- | --- | --- |
| 配信バケット（既定 `qazx7412-vrc-service-status-panel-<スタック名>-public`） | `cloudflare.R2Bucket` | 6 |
| 内部バケット（既定 `qazx7412-vrc-service-status-panel-<スタック名>-state`） | `cloudflare.R2Bucket` | 6 |
| `/v1/` 以下の Cache Rules | `cloudflare.Ruleset` | 6 |
| R2 の S3 互換トークン | `cloudflare.AccountToken` | 9 |
| yt-dlp と QuickJS の Layer（`qazx7412-vrc-service-status-panel-<スタック名>-ytdlp`） | `aws.lambda.LayerVersion` | 7.1、7.3 |
| 集約サーバー | `aws.lambda.Function` | 5.1 |
| ロググループと実行ロール | `aws.cloudwatch.LogGroup` / `aws.iam.Role` | — |
| 60 秒間隔の起動 | `aws.scheduler.Schedule` | 5.1 |

OIDC プロバイダ、デプロイロール、権限境界はここに無い。CLI で作ってあり、
中身は `docs/aws-oidc.md` にある。

バケット名の既定にスタック名が入るのは、同じアカウントで `dev` と `prod` を
並べたときに名前がぶつかるためである。決めた名前を使いたければ
`publicBucket` と `stateBucket` で明示する。

カスタムドメインは作らない。理由は下の「手で行う作業」にある。

### R2 のデータ用トークンの権限

Pulumi が発行するトークンは、配信バケットと内部バケットの二つに絞った
**Object Read & Write** である（仕様書 9）。

R2 のトークンに「書き込みのみ」の段階は無い。選べるのは Admin Read & Write、
Admin Read only、Object Read & Write、Object Read only の四つで、書けるのは
Admin Read & Write と Object Read & Write の二つである。どちらも読み取りを伴う。

その二つのうち Object 系を選ぶのは、バケット単位に絞れるためである。Admin 系は
絞れず、アカウントの R2 全体に届く。そのかわり Admin 系は Cloudflare の REST API
でも使えるのに対し、Object 系は S3 互換 API 専用で、REST API へ使うと 401 か 403 に
なる。集約サーバーが要るのは S3 互換 API での読み書きだけなので、狭いほうで足りる。

読み取りはどちらにせよ要る。内部バケットは、前回の状態を引き継ぐために毎回読む
（仕様書 5.2 の手順 4）。配信バケットの内容は CDN から誰でも読めるので、そこに
読み取りが付く実害は小さい。

鍵は一組にしてある。バケットごとに割れば片方が漏れたときの範囲は狭くなるが、
どちらも同じ関数の環境変数に入るので、関数を破られたときは両方とも取られる。
分けて効くのは書き手を別の関数へ割ったときで、いまの構成にその予定は無い。

## 関数を増やすとき

関数は `src/functions.ts` の `FUNCTIONS` に並べる。バイナリは一つで、`handler` の
文字列だけが違う。この文字列が `_HANDLER` として渡り、`backend/src/main.cr` の
`Runtime::Lambda.handler` の名前と一致したものが動く。

増やすときは次の三つを揃える。

1. `src/functions.ts` の `FUNCTIONS` に足す
2. `backend/src/main.cr` に同じ名前の `handler` を足す
3. `backend/src/main.cr` の `HANDLERS` に名前を足す

名前がずれると、その関数は起動時に `UnknownHandler` で落ちる。
黙って何もしない状態にはならない。

## 用意するもの

- Pulumi CLI
- AWS の資格情報（`aws configure` などで解決できる状態）
- Cloudflare の API トークン（下記）
- 状態の置き場所にする R2 バケット（下記）

GitHub Actions からデプロイするなら、AWS の鍵を Secrets へ置く必要はない。
OIDC のロールを CLI で作り、その ARN を Secrets へ入れる（`docs/aws-oidc.md`）。

R2 のデータ用の鍵は用意しなくてよい。Pulumi が発行し、そのまま Lambda へ渡す。

### Cloudflare の API トークン

ダッシュボードの「My Profile → API Tokens」から作る。

**渡し方は環境変数 `CLOUDFLARE_API_TOKEN` である。** スタックの設定には入れない。
プロバイダは設定からも環境変数からも読むが、設定へ入れると commit されるファイルに
暗号文が載る。公開する暗号文は少ないほうがよい（#24）。
CI は元からこの環境変数で渡している。

**権限ポリシー**を四つ足す。ポリシーごとに、まず対象を選ぶドロップダウン
（`アカウント全体`、`指定ドメイン` など）があり、その下で権限を選ぶ。
公式ドキュメントが Account / Zone と呼ぶ区別が、ここでは対象の選択にあたる。

| 対象 | 権限 | 何のため |
| --- | --- | --- |
| アカウント全体 | Workers R2 Storage | バケットの作成、削除、設定の変更 |
| アカウント全体 | Account API Tokens | R2 のデータ用トークンを発行する |
| アカウント全体 | Account Rulesets | Cache Rules |
| 指定ドメイン（配信ドメイン） | Cache Settings | Cache Rules |

どれも Read と Edit（Write）の両方を入れる。この画面は読み取りと書き込みを
別々の権限として扱っており、Edit だけでは読めない。

R2 は `アカウント全体` にする。`R2 バケット` を選ぶとバケット単位に絞れるが、
それはバケットの中身を触る権限であって、バケット自体は作れない。

**「Cache Rules」という項目は無い。** Cache Rules を触る権限の名前は
`Cache Settings` である。ドキュメントの本文は製品名で書かれているが、
権限の一覧は別の名前で並んでいる。

[公式の手順](https://developers.cloudflare.com/cache/how-to/cache-rules/create-api/)は
`Account Filter Lists` も挙げている。これはルールがリストを参照する場合のもので、
ここで作るルールは参照していない。入れずに始めて、`pulumi up` が 403 を返したら足す。

**Account API Tokens の重さは把握しておくこと。** これはトークンを作る権限で
あり、持たせた相手はアカウント内の任意の権限を持つトークンを発行できる。実質的に
管理者相当である。R2 のデータ用トークンを Pulumi に発行させる以上は避けられないが、
[IP 制限や TTL](https://developers.cloudflare.com/fundamentals/api/how-to/restrict-tokens/)
で使える範囲を狭められる。

## 状態の置き場所

R2 に置ける。S3 互換の DIY バックエンドとして扱う。

置き場所は `Pulumi.yaml` の `backend.url` で固定してある。バケットは
`qazx7412-vrc-service-status-panel-pulumi-state` である。

```yaml
backend:
  url: s3://qazx7412-vrc-service-status-panel-pulumi-state?endpoint=https://32cd31ff8a5c721c0583f57a83cb731e.r2.cloudflarestorage.com&s3ForcePathStyle=true&region=auto
```

ここで固定するのは、バックエンドがスタックより先に決まるためである。
`Pulumi.<スタック名>.yaml` の設定はバックエンドが決まってからでないと読めないので、
置き場所を書く先にはならない。`endpoint` にはスキームを付ける。ホスト名だけだと
接続先の URL として解決されない。

**fork して自分のアカウントへ出すときは、まずここを書き換える。** バケット名も
エンドポイントのアカウント ID も作者のものである。`cloudflareAccountId` を
自分のものに直しても、この URL はスタック設定より先に読まれるため、
書き換えないかぎり作者のアカウントへ繋ぎに行って認証で止まる。

CI からも流すなら、書き換える先はもう一つある。`docs/aws-oidc.md` のロールと境界を
自分のアカウントに作り直す。信頼ポリシーの `sub` は元のリポジトリを指しているので、
fork の Actions ではそのままロールを引けない。

**`pulumi login` は要らない。** 手元でも CI でも、要るのは R2 の鍵だけである。

```
export AWS_ACCESS_KEY_ID=<状態用R2のアクセスキーID>
# シークレットのほうは履歴に残さない
printf 'AWS_SECRET_ACCESS_KEY: '
read -rs AWS_SECRET_ACCESS_KEY && echo
export AWS_SECRET_ACCESS_KEY
# 一時的な AWS の資格情報を使っていたシェルなら、これを消す。
# 残っていると R2 への署名に AWS のセッショントークンが混ざって認証に失敗する
unset AWS_SESSION_TOKEN
```

バケットは先に手で作っておく。Pulumi の DIY バックエンドはバケットを作らず、
既にあるものを指すだけである。トークンを絞るときの候補にも、作ってからでないと
出てこない。順番は、バケット、トークン、`pulumi up` になる。

このバケットだけは Pulumi の管理外に置く。自分の状態を自分で管理させると、
作る前に置き場所が要ることになる。場所はどこでもよい。中身は state の JSON だけである。

**`src/delivery.ts` が作る内部バケットとは別物である。**
`qazx7412-vrc-service-status-panel-<スタック名>-state` のほうは集約サーバーが使うもので（仕様書 6）、
Pulumi が管理する。名前を分けてあるのはそのためで、同じにすると Pulumi が
自分の state の入っているバケットを作ろうとして衝突する。

鍵も手で作る。上の API トークンとは別物で、こちらは R2 のページから発行する。
「R2 object storage → Account Details → API Tokens → Manage → Create Account API token」。
権限は **Object Read & Write**、スコープは状態用バケットひとつに絞る。
Object 系のトークンは S3 互換 API でしか使えないが、DIY バックエンドが叩くのは
そちらなので足りる。Secret Access Key は作成直後の一度しか表示されない。

鍵は state の中で暗号化される。DIY バックエンドではパスフレーズから鍵を導くので、
`PULUMI_CONFIG_PASSPHRASE` を無くすと state を読めなくなる。控えておくこと。

### パスフレーズの作り方

**覚えずに作る。** 生成してパスワードマネージャへ入れる。

```
openssl rand -base64 32
```

`init-stack.sh` は 32 文字未満を受け付けない。

理由は commit する先が public だからである（#24）。
`Pulumi.<スタック名>.yaml` には secret が暗号文として入り、そのファイルは commit する。
暗号文が公開される以上、総当たりは誰でも好きなだけ試せる。

Pulumi の鍵導出は PBKDF2-SHA256 を 100 万回まわして AES-256-GCM の鍵を作る。
一回の試行が重いので、生成した値なら手が出ない。
一方、人が思いついて覚えられる範囲の文字列は、それでも辞書と規則の射程に入る。

文字種の規則は置いていない。規則を足すほど、生成した値が落ちて人が考えた値が通る、
という逆転が起きるためである。長さだけを見る。

### AWS の資格情報を分ける

上の `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` は R2 のものである。
AWS プロバイダの既定の探索順はこの環境変数を共有プロファイルより先に見るため、
そのままでは Lambda の操作にも R2 の鍵が使われて認証に失敗する。

AWS 側は `DEPLOY_AWS_*` で渡す。`src/providers.ts` がこれを AWS プロバイダから見た
`AWS_*` へ写しており、写しは元の変数がある場合だけ効く。

```
export DEPLOY_AWS_ACCESS_KEY_ID=<AWSのアクセスキーID>
export DEPLOY_AWS_SECRET_ACCESS_KEY=<AWSのシークレット>
# 一時的な資格情報なら DEPLOY_AWS_SESSION_TOKEN も
```

**プロファイルでは代わりにならない。** `AWS_PROFILE` を渡しても
`AWS_ACCESS_KEY_ID` は R2 のまま残り、環境変数のほうが先に見られる。
R2 をバックエンドにするなら、AWS 側は鍵で渡すことになる。

状態を R2 へ置かない場合はどれも要らない。`AWS_*` がそのまま使われ、
プロファイルも普通に使える。

写し替えが効くのは Pulumi の AWS プロバイダだけである。
同じシェルで `aws` コマンドを叩くときは、その場で `AWS_*` へ移す
（下のデプロイ手順を参照）。

## 設定の置き場所

スタックごとの値は `Pulumi.<スタック名>.yaml` に入る。**このファイルは commit する。**

`pulumi config set --secret` で入れた値は暗号文として記録される。復号の鍵は
パスフレーズから導く。**このリポジトリは public なので、暗号文もそのまま公開される。**
強度は「パスフレーズの作り方」に書いた条件で担保する。弱いパスフレーズなら、
持たない相手でも総当たりで導ける（#24）。

```yaml
config:
  vrc-service-status-panel:cloudflareAccountId: 023e105f4ecef8ad9ca31a8372d0c353
  vrc-service-status-panel:alertWebhookUrl:
    secure: v1:zXQ8kR2mN4pL:vT7hJ...
```

平文で入るのは識別子のほうである。アカウント ID、ゾーン ID、配信ホスト名、
バケット名、yt-dlp の版。

commit するのは、CI へ渡すものを減らすためである。ファイルを持たせない道もあるが、
その場合は値を GitHub の Secrets と Variables へ並べ直すことになり、設定を足すたびに
ワークフローも直すことになる。ずれても `pulumi up` が落ちて初めて気づく。
commit してあれば、CI へ渡すのは鍵と資格情報だけで済む。

**このリポジトリは public である。** 平文の識別子は読まれる前提で置いてある。

置いたままにできるのは、どれも識別子であって資格情報ではないためである。
OIDC のロールは `sub` で引ける相手を絞ってあるので、AWS のアカウント ID を
知られてもロールを引けるようにはならない。ただしロール名は推測できるようになる。
Cloudflare のアカウント ID とゾーン ID も、トークンと組にならなければ何もできない。

暗号文のほうは「パスフレーズの作り方」の条件で守る（#24）。

`Pulumi.example.yaml` は残してある。fork して自分のアカウントへ出すときは、
こちらを写す。commit されているほうには作者のアカウント ID と、作者のパスフレーズで
暗号化された値が入っている。

## デプロイ

`infra/deploy.sh` がひと通り流す。

```
printf 'CLOUDFLARE_API_TOKEN: '; read -rs cloudflare_token && echo

CLOUDFLARE_API_TOKEN="$cloudflare_token" infra/deploy.sh
CLOUDFLARE_API_TOKEN="$cloudflare_token" infra/deploy.sh --ytdlp 2025.09.26
```

`CLOUDFLARE_API_TOKEN` はスタックの設定に入らないので、流すときに渡す（#24）。
`deploy.sh` は最初に見て、無ければそこで止まる。

**`CLOUDFLARE_API_TOKEN` は export しない。** export すると、デプロイが終わったあとも
呼び出し元のシェルに残り、そこで動かすものすべてへ引き継がれる。この呼び出しにだけ
渡せば、そこで終わる。

`deploy.sh` の側でも、受け取ったらすぐ環境から外し、`pulumi up` へ渡すときだけ戻している。
渡ってきたまま進むと、`npm ci` が動かす依存パッケージのインストールスクリプトや、
`build.sh` が起こす docker まで、このトークンを見られることになる。
「Account API Tokens の重さ」で書いたとおり実質的に管理者相当なので、
Pulumi と無関係なコードへは渡さない。

`PULUMI_CONFIG_PASSPHRASE` のほうは export する。渡す先が一つではなく、
`init-stack.sh` も `deploy.sh` も中で `pulumi` を何度も呼ぶためである。

### この変更より前に作ったスタック

`deploy.sh` の前に `init-stack.sh` を流し直す。

設定から `cloudflare:apiToken` を落とすのも、`ytdlpLayerArn` を落として
`ytdlpLayerVersion` を `ytdlpVersion` へ引き継ぐのも、短いパスフレーズの入れ替えを
案内するのも `init-stack.sh` の中にある。`deploy.sh` だけを流すと、設定ファイルに
トークンの暗号文が残ったままになる。

```
printf 'PULUMI_CONFIG_PASSPHRASE: '; read -rs PULUMI_CONFIG_PASSPHRASE && echo
export PULUMI_CONFIG_PASSPHRASE

infra/init-stack.sh dev
```

聞かれる値には、いま入っているものが既定として出る。Enter で通せばそのまま残る。

`--ytdlp` は `ytdlpVersion` を書き換えるだけである。Layer そのものは Pulumi が
持つので、発行と関数への反映は同じ `pulumi up` の中で揃う（#8）。

Layer の zip は毎回用意される。`backend/layer/build.sh` は同じ版の zip が既に
あれば何もしないので、36 MiB を取り直すのは版を変えたときだけである。

`--ytdlp` 以外の引数はそのまま `pulumi up` へ渡る（`--yes` など）。

commit はしない。設定が変わったら `Pulumi.<スタック名>.yaml` を自分で残す。

### 初回にすること

`deploy.sh` は設定が埋まっている前提で動く。設定は `infra/init-stack.sh` が作る。

```
cd infra
npm ci

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

二度目以降に流すと、いま入っている値を既定として見せる。Enter で通せばそのまま残る。
秘密の値は見せずに「Enter で今の値のまま」と聞く。空で答えても消えないので、
消したいときは `pulumi config rm` を使う。

値は一つずつ聞かれる。省略できるものは空のまま Enter で飛ばせる。秘密の値は
標準入力から渡すので、コマンドラインにも履歴にも残らない。何を聞かれるかは
`Pulumi.example.yaml` に並べてある。

出来上がった `Pulumi.dev.yaml` は commit する（#12）。続きはスクリプトが最後に
案内する。

```
git add Pulumi.dev.yaml

printf 'CLOUDFLARE_API_TOKEN: '; read -rs cloudflare_token && echo
CLOUDFLARE_API_TOKEN="$cloudflare_token" ./deploy.sh
```

トークンを export せずにこの呼び出しへだけ渡すのは「デプロイ」に書いたとおりである。

Layer は `deploy.sh` の中の `pulumi up` が作る。版は `init-stack.sh` で入れた
`ytdlpVersion` を使うので、初回でも `--ytdlp` は要らない。あとから版を変えるときだけ
渡す。

```
CLOUDFLARE_API_TOKEN="$cloudflare_token" ./deploy.sh --ytdlp 2025.09.26
```

#### GitHub Actions からも流す場合

権限境界の ARN が要る。入れないと実行ロールに境界が付かず、手元からは通っても
CI からは `CreateRole` で止まる。

`init-stack.sh` が「GitHub Actions からの入口」で聞く。既定はいま繋がっている
AWS アカウントから組み立てたものなので、Enter で通せば入る。飛ばしていたら後から足す。

```
pulumi config set --stack dev workloadBoundaryArn \
  arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary

git add Pulumi.dev.yaml
```

Secrets へ登録するものは「ワークフローでの受け取り」にある。

### スクリプトが何をしているか

手で並べると次の三つになる。詰まったときはこの順で追う。

**どれも `infra/` から実行する。** 3 が `Pulumi.yaml` を要るためで、
そのぶん 1 と 2 は `../backend/...` を指す。

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

`pulumi up` は `../backend/bootstrap.zip` と `../backend/ytdlp-layer.zip` を
読むので、1 か 2 を飛ばすとそこで止まる。

Layer の発行は 3 の中で起きる。zip が前回と同じなら新しい版は作られない。

OIDC のロールと権限境界はこのスクリプトの対象外である。あちらは CI の権限そのものを
決める場所で、Pulumi に載せていない（「GitHub Actions から AWS へ入る」を参照）。

## 前提: ゾーンに既存の Cache Rules が無いこと

`deliveryZoneId` のゾーンで `http_request_cache_settings` を既に使っていると、
`pulumi up` はここで失敗する。`kind: "zone"` のこのフェーズは、ゾーンごとに
一つしか置けないためである。

既にある場合は取り込んでから、規則を `src/delivery.ts` の `rules` に並べ直す。

```
# 既存の ruleset の ID を調べる
curl -s -H "Authorization: Bearer $cloudflare_token" \
  "https://api.cloudflare.com/client/v4/zones/<ゾーンID>/rulesets/phases/http_request_cache_settings/entrypoint" \
  | jq -r '.result.id, (.result.rules[] | .expression)'

CLOUDFLARE_API_TOKEN="$cloudflare_token" \
  pulumi import cloudflare:index/ruleset:Ruleset delivery-cache <ゾーンID>/<rulesetのID>
```

取り込んだあと、既存の規則も `src/delivery.ts` に書き写す。書き漏らすと次の `pulumi up`
で消える。Pulumi は自分の定義を正として、そこに無い規則を落とすためである。

自動で取り込んで混ぜる作りにはしていない。こちらが置いた覚えのない規則を黙って
管理下に入れると、消えたことに気づけない。

## GitHub Actions から AWS へ入る

入口は Pulumi に無い。OIDC プロバイダ、デプロイロール、実行時ロールの権限境界は
AWS CLI で作ってあり、権限の一覧も作り直す手順も `docs/aws-oidc.md` にある。
長い寿命の鍵を Secrets へ置かずに済む。

ロールはリポジトリに対して一つで、`dev` と `prod` で同じものを使う。
引けるのは既定で `master` への push に限る。

### 本体へ渡すもの

境界の ARN を設定に入れる。

```
pulumi config set workloadBoundaryArn \
  arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary
```

これを入れないと、実行ロールに境界が付かない。手元から流す分にはそれでも通るが、
CI からは通らない。デプロイロールは境界の付いたロールしか作れず、
`CreateRole` がそこで止まる。

ロールの ARN は GitHub の Secrets に `AWS_DEPLOY_ROLE_ARN` として登録する。

### ワークフローでの受け取り

CI では `AWS_*` の取り合いが起きる。Pulumi の状態は R2 にあり、そのバックエンドが
`AWS_*` から R2 の鍵を読む。一方 `configure-aws-credentials` も既定では `AWS_*` を
書く。両方を `AWS_*` に置くことはできない。

`output-credentials: true` で受け取り、AWS 側は `DEPLOY_AWS_*` へ入れる。

```yaml
permissions:
  id-token: write   # OIDC のトークンを発行させる。既定では付かない
  contents: read

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

  - id: aws
    uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
      aws-region: ap-northeast-1
      output-credentials: true
      # ジョブの環境へ AWS_* を書かせない。
      # 既定では書かれるので、AWS_SESSION_TOKEN が後続へ残る。
      # 下で AWS_ACCESS_KEY_ID と AWS_SECRET_ACCESS_KEY だけを R2 のものへ
      # 差し替えると、R2 への署名に AWS のセッショントークンが混ざって失敗する
      output-env-credentials: false

  - run: npm ci
    working-directory: infra

  # Pulumi CLI はランナーに入っていない。
  # このアクションは command を渡さなければ CLI を入れるだけで終わる。
  # get.pulumi.com のスクリプトで入れてもよい
  - uses: pulumi/actions@v6

  # Layer の zip も .gitignore の対象で、checkout には入っていない。
  # src/layer.ts が FileArchive として開くので、bootstrap.zip と同じく
  # 無いと pulumi up はファイル未検出で止まる。
  #
  # 版は流す相手のスタックから読む。ここで別のスタックの版を渡すと、
  # 中身と description と YTDLP_VERSION が食い違う。
  # config get は Pulumi CLI が要るので、このステップは上より後に置く。
  - run: |
      backend/layer/build.sh \
        "$(pulumi -C infra config get --stack prod ytdlpVersion)" \
        "" backend/ytdlp-layer.zip
    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.PULUMI_STATE_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.PULUMI_STATE_SECRET_ACCESS_KEY }}
      PULUMI_CONFIG_PASSPHRASE: ${{ secrets.PULUMI_CONFIG_PASSPHRASE }}

  # スタック名は commit してある Pulumi.<スタック名>.yaml のものにする
  - run: pulumi up --yes --stack prod
    working-directory: infra
    env:
      # Pulumi の状態の置き場所（R2）
      AWS_ACCESS_KEY_ID: ${{ secrets.PULUMI_STATE_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.PULUMI_STATE_SECRET_ACCESS_KEY }}
      # 設定は checkout した Pulumi.prod.yaml から読まれる。
      # 暗号文で入っている値を開けるのに要る（「設定の置き場所」を参照）
      PULUMI_CONFIG_PASSPHRASE: ${{ secrets.PULUMI_CONFIG_PASSPHRASE }}
      # デプロイ先（AWS）。src/providers.ts がこれを AWS プロバイダの AWS_* へ写す
      DEPLOY_AWS_ACCESS_KEY_ID: ${{ steps.aws.outputs.aws-access-key-id }}
      DEPLOY_AWS_SECRET_ACCESS_KEY: ${{ steps.aws.outputs.aws-secret-access-key }}
      DEPLOY_AWS_SESSION_TOKEN: ${{ steps.aws.outputs.aws-session-token }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

`output-env-credentials: false` が使えない版なら、pulumi のステップで
`AWS_SESSION_TOKEN: ""` を明示しても同じことになる。

**この例は `prod` を更新する。** 動かすには `prod` のスタックを作り、その
`Pulumi.prod.yaml` を commit しておく必要がある。デプロイロールは `dev` と `prod` の
どちらにも届くので、ロールの側で用意するものは無い。

Layer を Pulumi に持たせたことで、デプロイロールには Layer の発行と削除も要る。
読み取りだけのままだと、最初の `PublishLayerVersion` で `AccessDenied` になる。
`docs/aws-oidc.md` のポリシーには入れてあり、実物のロールにも反映済みである。
ロールは CI から更新できない設計なので、権限を変えるときは手元から CLI で流す。

`pulumi login` のステップも、`pulumi config set` を並べるステップも要らない。
置き場所は `Pulumi.yaml` に、設定は `Pulumi.<スタック名>.yaml` にあり、
どちらも checkout した時点でそろっている。**そろっていないのはバイナリだけ**で、
これは `.gitignore` の対象なので毎回作る。

Layer の zip もバイナリと同じ扱いになる。どちらも `.gitignore` の対象なので、
`pulumi up` の前に作る（仕様書 7.1、7.3）。発行そのものは `pulumi up` の中で起きるので、
デプロイロールには Layer の発行と削除も与えてある。

デプロイのワークフロー自体はまだ無い。ここにあるのは受け取り方だけである。

### ロールの権限

`docs/aws-oidc.md` に一覧がある。名前の頭で絞ってあり、同じアカウントの他のリソースへは
届かない。このロール自身の権限を書き換える操作は Deny してあるので、CI からは変えられない。

実行ロールに付く権限境界も同じ文書にある。`src/roles.ts` が設定の `workloadBoundaryArn`
を渡すだけで、境界そのものはここに無い。

## 手で行う作業

**カスタムドメインの接続。** ダッシュボードで配信バケットに配信ホスト名を繋ぐ。
R2 → バケットを選ぶ → Settings → Custom Domains → Add。

繋ぐ先のバケット名は `pulumi stack output publicBucketOut` で確かめる。
既定のままなら `qazx7412-vrc-service-status-panel-<スタック名>-public` である。`publicBucket` を
設定している場合はその名前になる。

Pulumi に載せていないのは、`cloudflare_r2_custom_domain` に、作成の約一分後に
`enabled` が `false` へ戻る不具合があるためである
（[cloudflare/terraform-provider-cloudflare#6578](https://github.com/cloudflare/terraform-provider-cloudflare/issues/6578)）。
Pulumi の Cloudflare プロバイダは同じ Terraform プロバイダを包んだものなので、
同じ挙動になる。配信そのものが止まる箇所であり、載せる利より害が大きい。

不具合が直れば `src/delivery.ts` に `R2CustomDomain` を足すだけで済む。

## 確かめ方

```
npm run typecheck   # tsc --noEmit
pulumi preview      # 差分を見る
```

