# infra

集約サーバー（Lambda）と配信経路（R2）の定義。仕様書は #1 にある。

AWS と Cloudflare を一つの Pulumi プログラムにまとめている。
分けないのは、片側の値をもう片側が使うためである。
R2 のバケット名も、トークンから導いた鍵も、そのまま Lambda の環境変数になる。
分けて書くと、その受け渡しを人が写すことになり、鍵を替えたときに写し忘れる。

## 何を作るか

| 対象 | リソース | 仕様書 |
| --- | --- | --- |
| 配信バケット（既定 `status-public`） | `cloudflare.R2Bucket` | 6 |
| 内部バケット（既定 `status-state`） | `cloudflare.R2Bucket` | 6 |
| `/v1/` 以下の Cache Rules | `cloudflare.Ruleset` | 6 |
| R2 の S3 互換トークン | `cloudflare.AccountToken` | 9 |
| 集約サーバー | `aws.lambda.Function` | 5.1 |
| ロググループと実行ロール | `aws.cloudwatch.LogGroup` / `aws.iam.Role` | — |
| 60 秒間隔の起動 | `aws.scheduler.Schedule` | 5.1 |
| GitHub Actions 用の OIDC とロール（任意） | `aws.iam.OpenIdConnectProvider` / `aws.iam.Role` | — |

カスタムドメインは作らない。理由は下の「手で行う作業」にある。

## 関数を増やすとき

関数は `index.ts` の `FUNCTIONS` に並べる。バイナリは一つで、`handler` の
文字列だけが違う。この文字列が `_HANDLER` として渡り、`backend/src/main.cr` の
`Runtime::Lambda.handler` の名前と一致したものが動く。

増やすときは次の三つを揃える。

1. `index.ts` の `FUNCTIONS` に足す
2. `backend/src/main.cr` に同じ名前の `handler` を足す
3. `backend/src/main.cr` の `HANDLERS` に名前を足す

名前がずれると、その関数は起動時に `UnknownHandler` で落ちる。
黙って何もしない状態にはならない。

## 用意するもの

- Pulumi CLI
- AWS の資格情報（`aws configure` などで解決できる状態）
- Cloudflare の API トークン。R2 の編集、ゾーンの Cache Rules の編集、トークンの発行の三つが要る
- 状態の置き場所にする R2 バケット（下記）

GitHub Actions からデプロイするなら、AWS の鍵を Secrets へ置く必要はない。
OIDC のロールを作る（「GitHub Actions から AWS へ入る」を参照）。

R2 のデータ用の鍵は用意しなくてよい。Pulumi が発行し、そのまま Lambda へ渡す。

## 状態の置き場所

R2 に置ける。S3 互換の DIY バックエンドとして扱う。

```
export AWS_ACCESS_KEY_ID=<状態用R2のアクセスキーID>
export AWS_SECRET_ACCESS_KEY=<状態用R2のシークレット>
pulumi login 's3://<状態用バケット>?endpoint=<アカウントID>.r2.cloudflarestorage.com&s3ForcePathStyle=true&region=auto'
```

この状態用バケットだけは Pulumi の管理外に置き、手で作る。
自分の状態を自分で管理させると、作る前に置き場所が要ることになる。

鍵は state の中で暗号化される。DIY バックエンドではパスフレーズから鍵を導くので、
`PULUMI_CONFIG_PASSPHRASE` を無くすと state を読めなくなる。控えておくこと。

### AWS の資格情報を分ける

上の `AWS_ACCESS_KEY_ID` と `AWS_SECRET_ACCESS_KEY` は R2 のものである。
AWS プロバイダの既定の探索順はこの環境変数を共有プロファイルより先に見るため、
そのままでは Lambda の操作にも R2 の鍵が使われて認証に失敗する。

AWS 側は `DEPLOY_AWS_*` で渡す。`index.ts` がこれを AWS プロバイダから見た
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

## デプロイ

```
# 1. バイナリを作る（docker が要る）
backend/build.sh

# 2. Layer を発行し、ARN を控える（仕様書 7.1、7.3）
#
#    aws コマンドは Pulumi の写し替えを知らないため、AWS の鍵をその場で
#    AWS_* へ移す。R2 をバックエンドにしていない場合はこの前置きは要らない。
backend/layer/build.sh 2025.09.26
AWS_ACCESS_KEY_ID="$DEPLOY_AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$DEPLOY_AWS_SECRET_ACCESS_KEY" \
aws lambda publish-layer-version \
  --layer-name vrc-service-status-panel-ytdlp \
  --zip-file fileb://ytdlp-layer.zip \
  --compatible-runtimes provided.al2023 \
  --compatible-architectures arm64 \
  --query LayerVersionArn --output text

# 3. 値を入れる（初回のみ）
cd infra
npm ci
pulumi stack init dev
pulumi config set cloudflareAccountId <アカウントID>
pulumi config set ytdlpLayerArn <2で得たARN>
pulumi config set ytdlpLayerVersion 2025.09.26
# 残りは Pulumi.example.yaml を見て埋める

# 4. 反映する
pulumi up
```

`backend/build.sh` を先に走らせておくこと。
`pulumi up` は `../backend/bootstrap.zip` を読むので、無ければそこで止まる。

Layer を発行し直したときは `ytdlpLayerArn` と `ytdlpLayerVersion` の両方を
入れ替えてから `pulumi up` する。片方だけだと、実行時の版の比較が
食い違いを出し続ける（#8）。

## GitHub Actions から AWS へ入る

`githubRepository` を設定すると、OIDC のプロバイダとデプロイ用のロールを作る。
長い寿命の鍵を Secrets へ置かずに済む。設定しなければ何も作らない。

```
pulumi config set githubRepository limit7412/VRCServiceStatusPanel
```

アカウントに GitHub の OIDC プロバイダを既に置いてある場合は、その ARN を渡す。
プロバイダはアカウントに一つしか置けない。

```
pulumi config set githubOidcProviderArn arn:aws:iam::<アカウント>:oidc-provider/token.actions.githubusercontent.com
```

### 順番

ロールは、そのロールを作る `pulumi up` より後にしか存在しない。
最初の一回は手元の資格情報で実行する。以降は CI から引ける。

```
pulumi up                              # 手元で一度
pulumi stack output githubDeployRoleArnOut
```

### 誰が引けるか

既定は master への push に限る。広げるときは `githubDeploySubjects` に並べる。

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
  - id: aws
    uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
      aws-region: ap-northeast-1
      output-credentials: true

  - run: npx pulumi up --yes --stack prod
    working-directory: infra
    env:
      # Pulumi の状態の置き場所（R2）
      AWS_ACCESS_KEY_ID: ${{ secrets.PULUMI_STATE_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.PULUMI_STATE_SECRET_ACCESS_KEY }}
      PULUMI_CONFIG_PASSPHRASE: ${{ secrets.PULUMI_CONFIG_PASSPHRASE }}
      # デプロイ先（AWS）。index.ts がこれを AWS プロバイダの AWS_* へ写す
      DEPLOY_AWS_ACCESS_KEY_ID: ${{ steps.aws.outputs.aws-access-key-id }}
      DEPLOY_AWS_SECRET_ACCESS_KEY: ${{ steps.aws.outputs.aws-secret-access-key }}
      DEPLOY_AWS_SESSION_TOKEN: ${{ steps.aws.outputs.aws-session-token }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

デプロイのワークフロー自体はまだ無い。ここにあるのは受け取り方だけである。

### ロールの権限

このスタックが触る範囲だけを与えてある。名前の頭で絞っているので、同じアカウントの
他のリソースへは届かない。

ただし `vrc-service-status-panel-*` にはこのロール自身も含まれるため、権限を書き換えて
広げられてしまう。それを塞ぐ Deny を入れてある。読み取りは残してあり、Pulumi が
毎回このロールの差分を見られる。**このロール自体を変えるときは手元から `pulumi up` する。**

## 手で行う作業

**カスタムドメインの接続。** ダッシュボードで配信バケットに配信ホスト名を繋ぐ。
R2 → バケットを選ぶ → Settings → Custom Domains → Add。

繋ぐ先のバケット名は `pulumi stack output publicBucketOut` で確かめる。
`publicBucket` を既定から変えている場合、`status-public` は別のバケットか、
そもそも存在しない。

Pulumi に載せていないのは、`cloudflare_r2_custom_domain` に、作成の約一分後に
`enabled` が `false` へ戻る不具合があるためである
（[cloudflare/terraform-provider-cloudflare#6578](https://github.com/cloudflare/terraform-provider-cloudflare/issues/6578)）。
Pulumi の Cloudflare プロバイダは同じ Terraform プロバイダを包んだものなので、
同じ挙動になる。配信そのものが止まる箇所であり、載せる利より害が大きい。

不具合が直れば `index.ts` に `R2CustomDomain` を足すだけで済む。

## 確かめ方

```
npm run typecheck   # tsc --noEmit
pulumi preview      # 差分を見る
```
