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

## 何を作るか

`infra/`

| 対象 | リソース | 仕様書 |
| --- | --- | --- |
| 配信バケット（既定 `status-public-<スタック名>`） | `cloudflare.R2Bucket` | 6 |
| 内部バケット（既定 `status-state-<スタック名>`） | `cloudflare.R2Bucket` | 6 |
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

置き場所は先に作っておく。Pulumi の DIY バックエンドはバケットを作らず、
既にあるものを指すだけである。トークンを絞るときの候補にも、作ってからでないと
出てこない。順番は、バケット、トークン、`pulumi login` になる。

**この state 用バケットは、`index.ts` が作る内部バケットとは別物である。**
`status-state-<スタック名>` のほうは集約サーバーが使うもので（仕様書 6）、
Pulumi が管理する。同じ名前にすると、Pulumi が自分の state の入っている
バケットを作ろうとして衝突する。`pulumi-state` のようにはっきり分けること。

```
export AWS_ACCESS_KEY_ID=<状態用R2のアクセスキーID>
export AWS_SECRET_ACCESS_KEY=<状態用R2のシークレット>
# 一時的な AWS の資格情報を使っていたシェルなら、これを消す。
# 残っていると R2 への署名に AWS のセッショントークンが混ざって認証に失敗する
unset AWS_SESSION_TOKEN
pulumi login 's3://<状態用バケット>?endpoint=https://<アカウントID>.r2.cloudflarestorage.com&s3ForcePathStyle=true&region=auto'
```

`endpoint` にはスキームを付ける。ホスト名だけだと接続先の URL として解決されない。

この状態用バケットだけは Pulumi の管理外に置き、手で作る。
自分の状態を自分で管理させると、作る前に置き場所が要ることになる。
場所はどこでもよい。中身は state の JSON だけである。

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

```
# 1. バイナリを作る（docker が要る）
backend/build.sh

# 2. Layer を発行し、ARN を控える（仕様書 7.1、7.3）
#
#    aws コマンドは Pulumi の写し替えを知らないため、AWS の鍵をその場で
#    AWS_* へ移す。R2 をバックエンドにしていない場合はこの前置きは要らない。
#    一時的な資格情報ならセッショントークンも要る。
#
#    --region は aws:region と同じ値にする。Layer は関数と同じリージョンに
#    無いと結べない。CLI の既定リージョンに任せると、未設定なら止まり、
#    別のリージョンなら pulumi up まで気づけない。
backend/layer/build.sh 2025.09.26
AWS_ACCESS_KEY_ID="$DEPLOY_AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$DEPLOY_AWS_SECRET_ACCESS_KEY" \
AWS_SESSION_TOKEN="$DEPLOY_AWS_SESSION_TOKEN" \
aws lambda publish-layer-version \
  --region ap-northeast-1 \
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
# CI からデプロイするなら infra/oidc/ を先に流し、その出力を入れる
# pulumi config set workloadBoundaryArn <infra/oidc の workloadBoundaryArn>
# 残りは Pulumi.example.yaml を見て埋める

# 4. 反映する
pulumi up

# 5. 出来上がった Pulumi.dev.yaml を commit する
git add Pulumi.dev.yaml
```

`backend/build.sh` を先に走らせておくこと。
`pulumi up` は `../backend/bootstrap.zip` を読むので、無ければそこで止まる。

Layer を発行し直したときは `ytdlpLayerArn` と `ytdlpLayerVersion` の両方を
入れ替えてから `pulumi up` する。片方だけだと、実行時の版の比較が
食い違いを出し続ける（#8）。

## 前提: ゾーンに既存の Cache Rules が無いこと

`deliveryZoneId` のゾーンで `http_request_cache_settings` を既に使っていると、
`pulumi up` はここで失敗する。`kind: "zone"` のこのフェーズは、ゾーンごとに
一つしか置けないためである。

既にある場合は取り込んでから、規則を `index.ts` の `rules` に並べ直す。

```
# 既存の ruleset の ID を調べる
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<ゾーンID>/rulesets/phases/http_request_cache_settings/entrypoint" \
  | jq -r '.result.id, (.result.rules[] | .expression)'

pulumi import cloudflare:index/ruleset:Ruleset delivery-cache <ゾーンID>/<rulesetのID>
```

取り込んだあと、既存の規則も `index.ts` に書き写す。書き漏らすと次の `pulumi up`
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

env:
  # まっさらなランナーには pulumi の資格情報ファイルが無い。
  # 指定しないと既定の Pulumi Cloud を見に行って認証で止まる。
  # pulumi login を別に走らせる代わりに、これで置き場所を指す
  PULUMI_BACKEND_URL: s3://<状態用バケット>?endpoint=https://<アカウントID>.r2.cloudflarestorage.com&s3ForcePathStyle=true&region=auto

steps:
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

  - run: npx pulumi up --yes --stack prod
    working-directory: infra
    env:
      # Pulumi の状態の置き場所（R2）
      AWS_ACCESS_KEY_ID: ${{ secrets.PULUMI_STATE_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.PULUMI_STATE_SECRET_ACCESS_KEY }}
      # 設定は checkout した Pulumi.prod.yaml から読まれる。
      # 暗号文で入っている値を開けるのに要る（「設定の置き場所」を参照）
      PULUMI_CONFIG_PASSPHRASE: ${{ secrets.PULUMI_CONFIG_PASSPHRASE }}
      # デプロイ先（AWS）。index.ts がこれを AWS プロバイダの AWS_* へ写す
      DEPLOY_AWS_ACCESS_KEY_ID: ${{ steps.aws.outputs.aws-access-key-id }}
      DEPLOY_AWS_SECRET_ACCESS_KEY: ${{ steps.aws.outputs.aws-secret-access-key }}
      DEPLOY_AWS_SESSION_TOKEN: ${{ steps.aws.outputs.aws-session-token }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

`output-env-credentials: false` が使えない版なら、pulumi のステップで
`AWS_SESSION_TOKEN: ""` を明示しても同じことになる。

`pulumi config set` を並べるステップは要らない。設定は checkout した
`Pulumi.<スタック名>.yaml` にそろっている。

デプロイのワークフロー自体はまだ無い。ここにあるのは受け取り方だけである。

### ロールの権限

本体のスタックが触る範囲だけを与えてある。名前の頭で絞っているので、同じアカウントの
他のリソースへは届かない。スタック名まで含めて絞ってあり、`dev` のデプロイロールから
`prod` のロールや関数へは手が伸びない。

ただし `vrc-service-status-panel-<スタック名>-*` にはこのロール自身も含まれるため、
権限を書き換えて広げられてしまう。それを塞ぐ Deny を入れてある。読み取りは残してある。

OIDC のプロバイダ、デプロイロール、権限境界のどれも本体には無い。CI が流すのは本体
だけなので、CI からはこれらに触れられない。**変えるときは `infra/oidc/` を手元から流す。**

### 実行時ロールの権限境界

名前で絞るだけでは足りない。`vrc-service-status-panel-<スタック名>-*` には Lambda の
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
既定のままなら `status-public-<スタック名>` である。`publicBucket` を
設定している場合はその名前になる。

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

`infra/oidc/` も同じである。別の Pulumi プロジェクトなので、`npm ci` も
`pulumi stack` も別に持つ。

```
cd oidc
npm ci
npm run typecheck
```
