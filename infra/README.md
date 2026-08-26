# infra

集約サーバー（Lambda）と配信経路（R2）の定義。仕様書は #1 にある。

AWS と Cloudflare を一つの Pulumi プログラムにまとめている。
分けないのは、片側の値をもう片側が使うためである。
R2 のバケット名も、トークンから導いた鍵も、そのまま Lambda の環境変数になる。
分けて書くと、その受け渡しを人が写すことになり、鍵を替えたときに写し忘れる。

## 何を作るか

| 対象 | リソース | 仕様書 |
| --- | --- | --- |
| 配信バケット `status-public` | `cloudflare.R2Bucket` | 6 |
| 内部バケット `status-state` | `cloudflare.R2Bucket` | 6 |
| `/v1/` 以下の Cache Rules | `cloudflare.Ruleset` | 6 |
| R2 の S3 互換トークン | `cloudflare.AccountToken` | 9 |
| 集約サーバー | `aws.lambda.Function` | 5.1 |
| ロググループと実行ロール | `aws.cloudwatch.LogGroup` / `aws.iam.Role` | — |
| 60 秒間隔の起動 | `aws.scheduler.Schedule` | 5.1 |

カスタムドメインは作らない。理由は下の「手で行う作業」にある。

## 用意するもの

- Pulumi CLI
- AWS の資格情報（`aws configure` などで解決できる状態）
- Cloudflare の API トークン。R2 の編集、ゾーンの Cache Rules の編集、トークンの発行の三つが要る
- 状態の置き場所にする R2 バケット（下記）

R2 のデータ用の鍵は用意しなくてよい。Pulumi が発行し、そのまま Lambda へ渡す。

## 状態の置き場所

R2 に置ける。S3 互換の DIY バックエンドとして扱う。

```
export AWS_ACCESS_KEY_ID=<R2のアクセスキーID>
export AWS_SECRET_ACCESS_KEY=<R2のシークレット>
pulumi login 's3://<状態用バケット>?endpoint=<アカウントID>.r2.cloudflarestorage.com&s3ForcePathStyle=true&region=auto'
```

この状態用バケットだけは Pulumi の管理外に置き、手で作る。
自分の状態を自分で管理させると、作る前に置き場所が要ることになる。

鍵は state の中で暗号化される。DIY バックエンドではパスフレーズから鍵を導くので、
`PULUMI_CONFIG_PASSPHRASE` を無くすと state を読めなくなる。控えておくこと。

## デプロイ

```
# 1. バイナリを作る（docker が要る）
backend/build.sh

# 2. Layer を発行し、ARN を控える（仕様書 7.1、7.3）
backend/layer/build.sh 2025.09.26
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

## 手で行う作業

**カスタムドメインの接続。** ダッシュボードで `status-public` のバケットに
配信ホスト名を繋ぐ。R2 → バケットを選ぶ → Settings → Custom Domains → Add。

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
