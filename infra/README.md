# infra

集約サーバー（Lambda）と配信経路（R2）の定義。仕様書は #1 にある。

AWS と Cloudflare を一つの Pulumi プログラムにまとめている。
分けないのは、片側の値をもう片側が使うためである。
R2 のバケット名も、トークンから導いた鍵も、そのまま Lambda の環境変数になる。
分けて書くと、その受け渡しを人が写すことになり、鍵を替えたときに写し忘れる。

## 二つのプロジェクト

| ディレクトリ | 何を持つか | 誰が流すか |
| --- | --- | --- |
| `infra/` | 配信経路と集約サーバー。毎回のデプロイで動く | 手元 / CI |
| `infra/oidc/` | CI の入口と、実行時ロールの上限 | 手元だけ |

分けてあるのは、`infra/oidc/` が CI の権限そのものを決める場所だからである。
同じプログラムに置くと、CI が自分を縛っている境界を書き換えられることになり、
境界も入口も意味を失う。

`infra/oidc/` は普段は動かさない。CI を用意するとき、権限を変えるとき、
`sub` の条件を足すときにだけ、手元から流す。

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
| `qazx7412-vrc-service-status-panel-dev-github-deploy` | デプロイロール |
| `qazx7412-vrc-service-status-panel-dev-workload-boundary` | 権限境界 |

頭を作成者の名前から始めるのは、同じ AWS / Cloudflare アカウントに置いた
他のものと見分けるためである。デプロイロールの権限もこの頭で絞ってあり、
名前を外れたものへは手が届かない。

スタック名まで含めるので、同じアカウントに dev と prod を並べても衝突しない。

**スタック名は小文字、数字、ハイフンだけ、16 文字までにする。** Pulumi のスタック名は
これより緩く、大文字も `_` も長い名前も通るが、そのまま物理名にすると R2 は `_` を
受け付けず、AWS と R2 は長さで弾く。外れていれば `pulumi up` の最初で止まる。

16 文字は `qazx7412-vrc-service-status-panel-<スタック名>-github-deploy` から
逆算した値である。IAM ロール名の上限が 64 文字で、頭と接尾で 48 文字を使う。

handler 名にも同じ事情がある。関数名の上限は 64 文字で、`dev` なら 26 文字ほど残る。
外れていればこちらも `pulumi up` の最初で止まる。

Layer だけはこの規則の外にある。手で発行する不変の成果物で、dev と prod が
同じものを指すためである（`qazx7412-vrc-service-status-panel-ytdlp`）。

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
| `init-stack.sh` | スタックを作って設定を入れる。最初の一回だけ |
| `deploy.sh` | ビルドから `pulumi up` までをひと通り流す |
| `index.ts` | 環境変数の組み立てと出力 |
| `src/settings.ts` | スタックごとの設定 |
| `src/providers.ts` | AWS プロバイダ。R2 バックエンドとの鍵の取り合いを解く |
| `src/delivery.ts` | R2 のバケットと Cache Rules（仕様書 6） |
| `src/credentials.ts` | R2 の S3 互換トークンと、そこから導く鍵（仕様書 9） |
| `src/functions.ts` | 関数の一覧。増やすときはここ |
| `src/roles.ts` | 実行時のロール |
| `src/compute.ts` | Lambda、ロググループ、Scheduler（仕様書 5.1） |

`infra/oidc/` は一つのファイルに収まっているので分けていない。

## 何を作るか

`infra/`

| 対象 | リソース | 仕様書 |
| --- | --- | --- |
| 配信バケット（既定 `qazx7412-vrc-service-status-panel-<スタック名>-public`） | `cloudflare.R2Bucket` | 6 |
| 内部バケット（既定 `qazx7412-vrc-service-status-panel-<スタック名>-state`） | `cloudflare.R2Bucket` | 6 |
| `/v1/` 以下の Cache Rules | `cloudflare.Ruleset` | 6 |
| R2 の S3 互換トークン | `cloudflare.AccountToken` | 9 |
| 集約サーバー | `aws.lambda.Function` | 5.1 |
| ロググループと実行ロール | `aws.cloudwatch.LogGroup` / `aws.iam.Role` | — |
| 60 秒間隔の起動 | `aws.scheduler.Schedule` | 5.1 |

`infra/oidc/`

| 対象 | リソース | 仕様書 |
| --- | --- | --- |
| GitHub Actions 用の OIDC プロバイダ | `aws.iam.OpenIdConnectProvider` | — |
| デプロイロールとその権限 | `aws.iam.Role` / `aws.iam.RolePolicy` | — |
| 実行時ロールの権限境界 | `aws.iam.Policy` | — |

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
`infra/oidc/` を手元から一度流し、OIDC のロールを作る
（「GitHub Actions から AWS へ入る」を参照）。

R2 のデータ用の鍵は用意しなくてよい。Pulumi が発行し、そのまま Lambda へ渡す。

### Cloudflare の API トークン

ダッシュボードの「My Profile → API Tokens」から作る。

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

置き場所は `Pulumi.yaml` の `backend.url` で固定してある。`infra/` と
`infra/oidc/` の両方に同じ URL が書いてあり、バケットは
`qazx7412-vrc-service-status-panel-pulumi-state` ひとつを共有する。
プロジェクトとスタックで別のパスに入るので、混ざらない。

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
`infra/` と `infra/oidc/` の両方にある。

**`pulumi login` は要らない。** 手元でも CI でも、要るのは R2 の鍵だけである。

```
export AWS_ACCESS_KEY_ID=<状態用R2のアクセスキーID>
# シークレットのほうは履歴に残さない
read -rsp 'AWS_SECRET_ACCESS_KEY: ' AWS_SECRET_ACCESS_KEY && echo
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
パスフレーズから導くので、`PULUMI_CONFIG_PASSPHRASE` を持たない相手には読めない。

```yaml
config:
  vrc-service-status-panel:cloudflareAccountId: 023e105f4ecef8ad9ca31a8372d0c353
  vrc-service-status-panel:alertWebhookUrl:
    secure: v1:zXQ8kR2mN4pL:vT7hJ...
```

平文で入るのは識別子のほうである。アカウント ID、ゾーン ID、配信ホスト名、
バケット名、Layer の ARN。ARN には AWS のアカウント ID が含まれる。

commit するのは、CI へ渡すものを減らすためである。ファイルを持たせない道もあるが、
その場合は値を GitHub の Secrets と Variables へ並べ直すことになり、設定を足すたびに
ワークフローも直すことになる。ずれても `pulumi up` が落ちて初めて気づく。
commit してあれば、CI へ渡すのはパスフレーズひとつで済む。

このリポジトリは private である。公開するときは、平文の識別子が読まれる前提で
見直すこと。OIDC のロールは `sub` で引ける相手を絞ってあるので、AWS のアカウント ID
を知られてもロールを引けるようにはならない。ただしロール名は推測できるようになる。

`Pulumi.example.yaml` は残してある。fork して自分のアカウントへ出すときは、
こちらを写す。commit されているほうには作者のアカウント ID と、復号できない
暗号文が入っている。

## デプロイ

`infra/deploy.sh` がひと通り流す。

```
infra/deploy.sh                     # 今の設定のまま作り直す
infra/deploy.sh --ytdlp 2025.09.26  # Layer をこの版で発行し直してから流す
```

`--ytdlp` を付けたときだけ Layer を作り直す。`ytdlpLayerArn` と
`ytdlpLayerVersion` は必ず一緒に更新されるので、片方だけ古いまま残ることがない。
片方だけだと実行時の版の比較が食い違いを出し続ける（#8）。

`--ytdlp` 以外の引数はそのまま `pulumi up` へ渡る（`--yes` など）。

commit はしない。設定が変わったら `Pulumi.<スタック名>.yaml` を自分で残す。

### 初回にすること

`deploy.sh` は設定が埋まっている前提で動く。設定は `infra/init-stack.sh` が作る。

```
cd infra
npm ci

# 値を export の右辺に書かない。シェルの履歴に平文で残る。
# 履歴に残ったパスフレーズと commit 済みの設定ファイルがそろえば、
# Cloudflare のトークンもアラートの URL も復号できてしまう
read -rsp 'PULUMI_CONFIG_PASSPHRASE: ' PULUMI_CONFIG_PASSPHRASE && echo
export PULUMI_CONFIG_PASSPHRASE

./init-stack.sh dev
```

ファイルに置いてある場合は `PULUMI_CONFIG_PASSPHRASE_FILE` にその場所を渡してもよい。

最初に GitHub Actions からも流すかを聞く。流すなら、本体と `infra/oidc/` の両方に
同じ名前のスタックを作る。二つの名前がずれると、`dev` のデプロイロールでは `prod` を
触れないまま CI が `AccessDenied` で止まる。手元からだけ流すなら `infra/oidc/` は
作らない。使わない OIDC プロバイダと IAM ロールを作る権限まで要ることになるためで、
本体の `workloadBoundaryArn` は省略できる。

二度目以降に流すと、いま入っている値を既定として見せる。Enter で通せばそのまま残る。
秘密の値は見せずに「Enter で今の値のまま」と聞く。空で答えても消えないので、
消したいときは `pulumi config rm` を使う。

値は一つずつ聞かれる。省略できるものは空のまま Enter で飛ばせる。秘密の値は
標準入力から渡すので、コマンドラインにも履歴にも残らない。何を聞かれるかは
`Pulumi.example.yaml` に並べてある。

出来上がった `Pulumi.dev.yaml` は commit する（#12）。続きはスクリプトが最後に
案内する。

```
# ARN はまだ無いので、初回は必ず版を渡す
./deploy.sh --ytdlp 2025.09.26

git add Pulumi.dev.yaml
```

#### GitHub Actions からも流す場合

`infra/oidc/Pulumi.dev.yaml` も出来ているので、こちらも commit する。
`deploy.sh` の前に、入口と権限境界を作って、その出力を本体へ入れる。

```
# infra/oidc/ は package-lock を別に持つ。infra/ の npm ci では入らない
npm ci --prefix oidc
pulumi -C oidc up

pulumi config set --stack dev workloadBoundaryArn $(pulumi -C oidc stack output workloadBoundaryArn)

git add Pulumi.dev.yaml oidc/Pulumi.dev.yaml
```

Secrets へ登録するものは「ワークフローでの受け取り」にある。

### スクリプトが何をしているか

手で並べると次の四つになる。詰まったときはこの順で追う。

**どれも `infra/` から実行する。** 3 と 4 が `Pulumi.yaml` を要るためで、
そのぶん 1 と 2 は `../backend/...` を指す。

```
cd infra

# 1. バイナリを作る（docker が要る）
../backend/build.sh

# 2. Layer を発行し、ARN を控える（仕様書 7.1、7.3）
#
#    aws コマンドは Pulumi の写し替えを知らないため、AWS の鍵をその場で
#    AWS_* へ移す。R2 をバックエンドにしていない場合はこの前置きは要らない。
#
#    --region は aws:region と同じ値にする。Layer は関数と同じリージョンに
#    無いと結べない。CLI の既定リージョンに任せると、未設定なら止まり、
#    別のリージョンなら pulumi up まで気づけない。
../backend/layer/build.sh 2025.09.26 "" "$PWD/ytdlp-layer.zip"
AWS_ACCESS_KEY_ID="$DEPLOY_AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$DEPLOY_AWS_SECRET_ACCESS_KEY" \
AWS_SESSION_TOKEN="$DEPLOY_AWS_SESSION_TOKEN" \
aws lambda publish-layer-version \
  --region ap-northeast-1 \
  --layer-name qazx7412-vrc-service-status-panel-ytdlp \
  --zip-file fileb://ytdlp-layer.zip \
  --compatible-runtimes provided.al2023 \
  --compatible-architectures arm64 \
  --query LayerVersionArn --output text

# 3. ARN と版を入れる
pulumi config set ytdlpLayerArn <2で得たARN>
pulumi config set ytdlpLayerVersion 2025.09.26

# 4. 反映する
pulumi up
```

`pulumi up` は `../backend/bootstrap.zip` を読むので、1 を飛ばすとそこで止まる。

`infra/oidc/` はこのスクリプトの対象外である。あちらは CI の権限そのものを
決める場所で、普段は流さない（「GitHub Actions から AWS へ入る」を参照）。

## 前提: ゾーンに既存の Cache Rules が無いこと

`deliveryZoneId` のゾーンで `http_request_cache_settings` を既に使っていると、
`pulumi up` はここで失敗する。`kind: "zone"` のこのフェーズは、ゾーンごとに
一つしか置けないためである。

既にある場合は取り込んでから、規則を `src/delivery.ts` の `rules` に並べ直す。

```
# 既存の ruleset の ID を調べる
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<ゾーンID>/rulesets/phases/http_request_cache_settings/entrypoint" \
  | jq -r '.result.id, (.result.rules[] | .expression)'

pulumi import cloudflare:index/ruleset:Ruleset delivery-cache <ゾーンID>/<rulesetのID>
```

取り込んだあと、既存の規則も `src/delivery.ts` に書き写す。書き漏らすと次の `pulumi up`
で消える。Pulumi は自分の定義を正として、そこに無い規則を落とすためである。

自動で取り込んで混ぜる作りにはしていない。こちらが置いた覚えのない規則を黙って
管理下に入れると、消えたことに気づけない。

## GitHub Actions から AWS へ入る

入口は `infra/oidc/` にある。**このプロジェクトは手元からだけ流す。**
長い寿命の鍵を Secrets へ置かずに済む。CI を使わないなら流さなくてよい。

```
cd infra/oidc
npm ci
pulumi stack init dev            # 本体と同じスタック名にする
pulumi config set githubRepository limit7412/VRCServiceStatusPanel
pulumi up
```

スタック名は本体と揃える。ロール名も境界も本体のスタック名から組み立てており、
名前が揃っていないと権限の範囲がずれる。揃えられない事情があるときだけ
`targetStack` に本体のスタック名を入れる。

アカウントに GitHub の OIDC プロバイダを既に置いてある場合は、その ARN を渡す。
プロバイダはアカウントに一つしか置けない。

```
pulumi config set githubOidcProviderArn arn:aws:iam::<アカウント>:oidc-provider/token.actions.githubusercontent.com
```

### 本体へ渡すもの

`infra/oidc/` の出力を二つ使う。

```
pulumi stack output workloadBoundaryArn   # 本体の設定に入れる
pulumi stack output githubDeployRoleArn   # GitHub の Secrets に入れる
```

```
cd ../
pulumi config set workloadBoundaryArn <上で得たARN>
```

`workloadBoundaryArn` を入れないと、実行ロールに境界が付かない。手元から流す分には
それでも通るが、CI からは通らない。デプロイロールは境界の付いたロールしか作れず、
`CreateRole` がそこで止まる。

### 順番

境界とロールが先である。本体の `pulumi up` は境界の ARN を要求するだけで、
それを作りはしない。

1. `infra/oidc/` を手元から流す
2. 出力を本体の `workloadBoundaryArn` と GitHub の Secrets へ写す
3. 本体を流す（一度目は手元から。以降は CI から引ける）

### 誰が引けるか

既定は master への push に限る。広げるときは `githubDeploySubjects` に並べる。
これも `infra/oidc/` の設定である。

```
pulumi config set --path githubDeploySubjects[0] 'repo:limit7412/VRCServiceStatusPanel:ref:refs/heads/master'
pulumi config set --path githubDeploySubjects[1] 'repo:limit7412/VRCServiceStatusPanel:environment:prod'
```

`sub` を絞らないと、同じ発行者の JWT を持つ任意のリポジトリからロールを引ける。
GitHub Actions の OIDC でいちばん間違えやすい箇所である。

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

  # スタック名は infra/oidc/ を流したときのものと揃える。
  # dev のデプロイロールは prod の関数にもロールにも手が届かない
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

**この例は `prod` を更新する。** 動かすには `infra/oidc/` を `prod` のスタックで
流し、`prod` のデプロイロールと境界を作っておく必要がある。上の手順は例として
`dev` を使っているので、CI から出す環境の分は別に作る。デプロイロールが許すのは
自分と同じスタック名の接頭辞だけで、`dev` のロールで `prod` を触ると
AccessDenied になる。

`pulumi login` のステップも、`pulumi config set` を並べるステップも要らない。
置き場所は `Pulumi.yaml` に、設定は `Pulumi.<スタック名>.yaml` にあり、
どちらも checkout した時点でそろっている。**そろっていないのはバイナリだけ**で、
これは `.gitignore` の対象なので毎回作る。

Layer はここでは発行しない。手で発行して ARN を設定へ入れる形にしてあり、
CI のデプロイロールにも Layer の読み取りしか与えていない（仕様書 7.1、7.3）。

デプロイのワークフロー自体はまだ無い。ここにあるのは受け取り方だけである。

### ロールの権限

本体のスタックが触る範囲だけを与えてある。名前の頭で絞っているので、同じアカウントの
他のリソースへは届かない。スタック名まで含めて絞ってあり、`dev` のデプロイロールから
`prod` のロールや関数へは手が伸びない。

ただし `qazx7412-vrc-service-status-panel-<スタック名>-*` にはこのロール自身も含まれるため、
権限を書き換えて広げられてしまう。それを塞ぐ Deny を入れてある。読み取りは残してある。

OIDC のプロバイダ、デプロイロール、権限境界のどれも本体には無い。CI が流すのは本体
だけなので、CI からはこれらに触れられない。**変えるときは `infra/oidc/` を手元から流す。**

### 実行時ロールの権限境界

名前で絞るだけでは足りない。`qazx7412-vrc-service-status-panel-<スタック名>-*` には Lambda の
実行ロールも入るので、次の順で昇格できてしまう。

1. デプロイロールで実行ロールへ任意のポリシーを足す
2. `lambda:UpdateFunctionCode` でコードを差し替える
3. 次の Scheduler の起動で、その権限のまま動く

そこで実行ロールと Scheduler のロールに**権限境界**を付けてある。境界は上限であって
付与ではない。境界に無いものは、ロールのポリシーで許しても効かない。

境界が許すのはこれだけである。

| 何 | 範囲 |
| --- | --- |
| `logs:CreateLogStream` / `logs:PutLogEvents` | このスタックのロググループ |
| `lambda:InvokeFunction` | このスタックの関数 |

デプロイロールの側も合わせてある。

- `iam:CreateRole` と `iam:PutRolePermissionsBoundary` は、要求に入る境界がこの境界と一致する場合だけ許す。境界の無いロールは作れない
- `iam:PutRolePolicy` などポリシーを足し引きする操作も、相手のロールにこの境界が付いている場合だけ許す
- `iam:DeleteRole` と `iam:UpdateAssumeRolePolicy` には条件を掛けない。この二つは `iam:PermissionsBoundary` の対象に入っておらず、掛けると Allow が成立しなくなる。境界の無いロールはそもそも作れないので、ここへ届く相手はどれも境界付きである
- `iam:DeleteRolePermissionsBoundary` を Deny する。境界を外す道を塞ぐ
- 境界そのもの（`aws.iam.Policy`）は本体に無い。書き換える操作は明示的に Deny してもある

**境界を変えるときは `infra/oidc/` を手元から流す。** デプロイロール自身と同じ扱いである。

なお、関数の環境変数に入る R2 の鍵はこの境界の外にある。コードを差し替えられれば
その鍵は使われる。境界が抑えるのは AWS 側の権限であって、関数が持つ資格情報ではない。

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

`infra/oidc/` も同じである。別の Pulumi プロジェクトなので、`npm ci` も
`pulumi stack` も別に持つ。

```
cd oidc
npm ci
npm run typecheck
```
