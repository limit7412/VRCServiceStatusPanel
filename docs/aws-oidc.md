# GitHub Actions から AWS へ入る

CI が AWS を触るための入口。
OIDC で短命の資格情報を受け取るので、長い寿命の AWS の鍵を Secrets へ置かずに済む。

**ここに書いたものは Pulumi で管理していない。** AWS CLI で作り、この文書に記録してある。
理由は最後の「Pulumi に載せない理由」にある。

## 作ってあるもの

以下の `<アカウントID>` は伏せ字である。実物の ARN には AWS のアカウント ID が入る。
このリポジトリは public なので書かない。手元では次で引ける。

```
aws sts get-caller-identity --query Account --output text
```

**設定ファイルにも書かない。** スタックの設定が持つのは境界の名前だけで、
ARN は `infra/src/roles.ts` がその場のアカウントから組む（#26）。
`Pulumi.<スタック名>.yaml` は commit するので、ここに ARN を置くと
アカウント ID がそのまま載ることになる。

`arn:aws:` の `aws`、`ap-northeast-1`、`limit7412/VRCServiceStatusPanel` は
伏せ字ではなく、いま動いているものの実際の値である。
**fork したり、別のリージョンやパーティションへ出したりするなら、この三つも書き換える。**
リージョンは Lambda、Logs、Scheduler の ARN に入っており、スタックの `aws:region` と
揃っていないとデプロイが `AccessDenied` になる。
リポジトリは信頼ポリシーの `sub` に入っており、揃っていないとロールを引けない。

| 何 | 名前 | 作った経路 |
| --- | --- | --- |
| OIDC プロバイダ | `token.actions.githubusercontent.com` | 既にアカウントにあったものを使う |
| デプロイロール | `qazx7412-vrc-service-status-panel-github-deploy` | CLI |
| 実行時ロールの権限境界 | `qazx7412-vrc-service-status-panel-workload-boundary` | CLI |

```
arn:aws:iam::<アカウントID>:oidc-provider/token.actions.githubusercontent.com
arn:aws:iam::<アカウントID>:role/qazx7412-vrc-service-status-panel-github-deploy
arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary
```

ロールと境界にスタック名を入れていない。
リポジトリに対して一つあればよく、`dev` と `prod` で同じものを使う。
そのぶん、`dev` のデプロイでも `prod` の関数とロールに手が届く。
同じワークフローが両方を出す以上、ここを分けても防げるものが無いため、こう決めた。

**その代わり、全スタックを同じリージョンに置く。** ポリシーと境界の ARN は
リージョンを一つしか書けないので、`dev` と `prod` の `aws:region` が違うと、
どちらか一方の Lambda、Logs、Scheduler の操作が `AccessDenied` になる。
仕様書 5.1 が東京に決めており、`infra/src/settings.ts` の既定もそこである。

どうしてもリージョンを分けるなら、ロールと境界もリージョンごとに分ける。
名前に `-<リージョン>` を挟み、スタックごとに引く相手を変えることになる。
いまその必要は無いので作っていない。

## OIDC プロバイダ

アカウントに一つしか置けない。
このアカウントには既にあったので、新しく作らずに参照している。

**消さないこと。** 同じアカウントの他のリポジトリも同じプロバイダを使っている可能性があり、
消すとそれらの CI もまとめて止まる。

指紋（`ThumbprintList`）は渡していない。
GitHub を含むいくつかの発行者について、AWS は自前の信頼された CA で検証し、指紋を見ない。

## 誰がロールを引けるか

信頼ポリシーで、`master` の ref で動くワークフローに限っている。
`sub` はイベントの種別を持たないので、push に限る書き方はできない。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<アカウントID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:limit7412/VRCServiceStatusPanel:ref:refs/heads/master",
            "repo:limit7412@19320218/VRCServiceStatusPanel@1346007387:ref:refs/heads/master"
          ]
        }
      }
    }
  ]
}
```

`sub` が二つ並んでいるのは、GitHub がこの claim の形を移している途中だからである。
古い形は `repo:<owner>/<repo>` で始まる。
新しい形は所有者とリポジトリの数値 ID を足した `repo:<owner>@<所有者ID>/<repo>@<リポジトリID>` になる。
数値 ID は名前を変えても変わらないので、リポジトリを消したり改名したりして空いた名前を
別のリポジトリが取っても、同じ `sub` を名乗れない。

いまこのリポジトリのランナーが受け取るのは新しい形である。

```
sub=repo:limit7412@19320218/VRCServiceStatusPanel@1346007387:ref:refs/heads/master
```

古い形だけを書いていたころ、`configure-aws-credentials` は
`Not authorized to perform sts:AssumeRoleWithWebIdentity` で止まっていた（#41）。
`gh api /repos/limit7412/VRCServiceStatusPanel/actions/oidc/customization/sub` は
`use_immutable_subject` に `false` を返すが、実際に届くトークンはこの形だった。
設定の返り値ではなく、届いたトークンの `sub` が正である。

両方を並べてあるのは、どちらの形で来ても通るようにするためである。
どちらもワイルドカードを含まない完全一致なので、並べたぶん引ける相手が増えることはない。

`sub` を絞らないと、同じ発行者の JWT を持つ任意のリポジトリからこのロールを引ける。
GitHub Actions の OIDC でいちばん間違えやすい箇所である。
IAM 側も、GitHub の発行者を信頼するロールについては `sub` 条件の有無を作成時に検査し、
ワイルドカードだけの値を弾く。

**fork したなら `repo:` の後ろを自分のものに書き換える。** `owner/repo` と、新しい形の
数値 ID の両方である。
ここが元のリポジトリを指したままだと、fork の GitHub Actions が出すトークンの `sub` と噛み合わず、
アカウント ID を正しく直してもロールを引けない。
数値 ID は次で引ける。

```
gh api /repos/<owner>/<repo> --jq '"\(.owner.id) \(.id)"'
```

いまの条件では、`master` に push できる者と `master` 上で `workflow_dispatch` を打てる者は
誰でも引ける。
さらに絞るなら、GitHub の environment を作って protection rules を掛け、
`sub` に `repo:limit7412/VRCServiceStatusPanel:environment:prod` を足す。

## デプロイロールの権限

インラインポリシー `deploy` として付けてある。
すべて `qazx7412-vrc-service-status-panel-` で始まる名前に絞ってあり、
同じアカウントの他のものへは届かない。

Layer に発行と削除まで与えているのは、yt-dlp の Layer を Pulumi が持つためである
（`infra/src/layer.ts`）。中身が変われば新しい版が出来て、関数を新しい ARN へ
繋ぎ替えてから古い版が消える。
Layer 名は `qazx7412-vrc-service-status-panel-<スタック名>-ytdlp` だが、ここは
スタック名を挟まない形で絞ってある。ロールを `dev` と `prod` で共有しているので、
どちらの Layer にも届く必要がある。

Lambda、Logs、Scheduler の ARN にはリージョンが入る。
Pulumi が組み立てていたころは `aws:region` から取っていたが、いまは書き下してある。
**リージョンを変えるときは、このポリシーも境界も作り直す。**
一つのポリシーに書けるリージョンは一つなので、変えるなら全スタックまとめて動かす。

| Sid | 何を許すか |
| --- | --- |
| `FunctionsRead` | 関数の読み取り |
| `FunctionsWrite` | 関数の作成、削除、コードと設定の更新 |
| `Layers` | Layer の発行、読み取り、削除 |
| `ReadRoles` | ロールの読み取りと受け渡し |
| `CreateBoundedRoles` | 権限境界の付いたロールだけを作る |
| `WriteBoundedRolePolicies` | 権限境界の付いたロールにだけポリシーを足し引きする |
| `WriteRoles` | ロールの削除と信頼ポリシーの更新 |
| `DenyBoundaryRemoval` | 境界を外す操作を塞ぐ |
| `DenyBoundaryEdit` | 境界の中身を書き換える操作を塞ぐ |
| `LogGroups` | ロググループの作成、削除、保持期間 |
| `DescribeLogGroups` | 一覧。リソース単位で絞れない |
| `Schedules` | EventBridge Scheduler の作成、削除、更新 |
| `DenySelfEscalation` | このロール自身の権限を書き換える操作を塞ぐ |

読み取りを `lambda:Get*` と `lambda:List*` でまとめてあるのは、Pulumi が指定していない
項目もドリフト検出のために読みに行くためである。
一つずつ並べると、足りない一つが見つかるたびに CI が止まる。

`CreateBoundedRoles` と `WriteBoundedRolePolicies` の条件は、境界の無いロールを作らせない
ためのものである。
境界の無いロールを作られると、そこへ任意の権限を足し、`lambda:UpdateFunctionCode` で
コードを差し替えて乗っ取れる。

`WriteRoles` の二つには条件を掛けていない。
緩くしても昇格には繋がらない。
境界の無いロールは上の条件で作れないため、ここへ届く相手はどれも境界付きであり、
信頼先を書き換えても上限は変わらない。

`DenySelfEscalation` があるので、**このロール自身の権限は CI から変えられない。**
変えるときは手元から CLI で行う。
読み取りは残してある。塞ぐと Pulumi がこのロールの差分を見られなくなる。

<details>
<summary>ポリシー全文</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "FunctionsRead",
      "Effect": "Allow",
      "Action": ["lambda:Get*", "lambda:List*"],
      "Resource": "arn:aws:lambda:ap-northeast-1:<アカウントID>:function:qazx7412-vrc-service-status-panel-*"
    },
    {
      "Sid": "FunctionsWrite",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:DeleteFunction",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration"
      ],
      "Resource": "arn:aws:lambda:ap-northeast-1:<アカウントID>:function:qazx7412-vrc-service-status-panel-*"
    },
    {
      "Sid": "Layers",
      "Effect": "Allow",
      "Action": [
        "lambda:DeleteLayerVersion",
        "lambda:GetLayerVersion",
        "lambda:ListLayerVersions",
        "lambda:PublishLayerVersion"
      ],
      "Resource": "arn:aws:lambda:ap-northeast-1:<アカウントID>:layer:qazx7412-vrc-service-status-panel-*"
    },
    {
      "Sid": "ReadRoles",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListRoleTags",
        "iam:PassRole",
        "iam:TagRole",
        "iam:UntagRole"
      ],
      "Resource": "arn:aws:iam::<アカウントID>:role/qazx7412-vrc-service-status-panel-*"
    },
    {
      "Sid": "CreateBoundedRoles",
      "Effect": "Allow",
      "Action": ["iam:CreateRole", "iam:PutRolePermissionsBoundary"],
      "Resource": "arn:aws:iam::<アカウントID>:role/qazx7412-vrc-service-status-panel-*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary"
        }
      }
    },
    {
      "Sid": "WriteBoundedRolePolicies",
      "Effect": "Allow",
      "Action": [
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy"
      ],
      "Resource": "arn:aws:iam::<アカウントID>:role/qazx7412-vrc-service-status-panel-*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary"
        }
      }
    },
    {
      "Sid": "WriteRoles",
      "Effect": "Allow",
      "Action": ["iam:DeleteRole", "iam:UpdateAssumeRolePolicy"],
      "Resource": "arn:aws:iam::<アカウントID>:role/qazx7412-vrc-service-status-panel-*"
    },
    {
      "Sid": "DenyBoundaryRemoval",
      "Effect": "Deny",
      "Action": "iam:DeleteRolePermissionsBoundary",
      "Resource": "arn:aws:iam::<アカウントID>:role/qazx7412-vrc-service-status-panel-*"
    },
    {
      "Sid": "DenyBoundaryEdit",
      "Effect": "Deny",
      "Action": [
        "iam:CreatePolicyVersion",
        "iam:DeletePolicy",
        "iam:DeletePolicyVersion",
        "iam:SetDefaultPolicyVersion"
      ],
      "Resource": "arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary"
    },
    {
      "Sid": "LogGroups",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:DeleteLogGroup",
        "logs:PutRetentionPolicy",
        "logs:DeleteRetentionPolicy",
        "logs:ListTagsForResource",
        "logs:TagResource",
        "logs:UntagResource"
      ],
      "Resource": "arn:aws:logs:ap-northeast-1:<アカウントID>:log-group:/aws/lambda/qazx7412-vrc-service-status-panel-*"
    },
    {
      "Sid": "DescribeLogGroups",
      "Effect": "Allow",
      "Action": "logs:DescribeLogGroups",
      "Resource": "*"
    },
    {
      "Sid": "Schedules",
      "Effect": "Allow",
      "Action": [
        "scheduler:CreateSchedule",
        "scheduler:DeleteSchedule",
        "scheduler:GetSchedule",
        "scheduler:UpdateSchedule",
        "scheduler:ListTagsForResource",
        "scheduler:TagResource",
        "scheduler:UntagResource"
      ],
      "Resource": "arn:aws:scheduler:ap-northeast-1:<アカウントID>:schedule/default/qazx7412-vrc-service-status-panel-*"
    },
    {
      "Sid": "DenySelfEscalation",
      "Effect": "Deny",
      "Action": [
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:PutRolePolicy",
        "iam:PutRolePermissionsBoundary",
        "iam:UpdateAssumeRolePolicy"
      ],
      "Resource": "arn:aws:iam::<アカウントID>:role/qazx7412-vrc-service-status-panel-github-deploy"
    }
  ]
}
```

</details>

## 実行時ロールの権限境界

名前で絞るだけでは足りない。
`qazx7412-vrc-service-status-panel-*` には Lambda の実行ロールも入るので、次の順で昇格できてしまう。

1. デプロイロールで実行ロールへ任意のポリシーを足す
2. `lambda:UpdateFunctionCode` でコードを差し替える
3. 次の Scheduler の起動で、その権限のまま動く

そこで実行ロールと Scheduler のロールに権限境界を付ける。
境界は上限であって付与ではない。
境界に無いものは、ロールのポリシーで許しても効かない。

境界が許すのはこれだけである。

| 何 | 範囲 |
| --- | --- |
| `logs:CreateLogStream` / `logs:PutLogEvents` | このプロジェクトのロググループ |
| `lambda:InvokeFunction` | このプロジェクトの関数 |

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteOwnLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:ap-northeast-1:<アカウントID>:log-group:/aws/lambda/qazx7412-vrc-service-status-panel-*:*"
    },
    {
      "Sid": "InvokeOwnFunctions",
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "arn:aws:lambda:ap-northeast-1:<アカウントID>:function:qazx7412-vrc-service-status-panel-*"
    }
  ]
}
```

境界を付けるのは Pulumi の側である。
設定 `workloadBoundaryName` に境界の名前を入れると、`infra/src/roles.ts` が
`aws.getCallerIdentityOutput()` で引いたアカウント ID と組み合わせて ARN にし、
`permissionsBoundary` へ渡す。
この値を入れ忘れると境界の付かないロールを作ろうとし、`CreateBoundedRoles` の条件を
満たさないため CI が `AccessDenied` で止まる。

引く先はデプロイ先と同じアカウントに限る。別のアカウントの境界を指す道は無い。
必要になったら、そのときに設定を ARN へ戻すことになる。

なお、関数の環境変数に入る R2 の鍵はこの境界の外にある。
コードを差し替えられればその鍵は使われる。
境界が抑えるのは AWS 側の権限であって、関数が持つ資格情報ではない。

## 作り直すとき

管理者の資格情報で、次を順に流す。
上の JSON を、それぞれ次の名前で保存しておく。

| 節 | 保存先 |
| --- | --- |
| 「誰がロールを引けるか」の信頼ポリシー | `trust.json` |
| 「デプロイロールの権限」のポリシー全文 | `deploy-policy.json` |
| 「実行時ロールの権限境界」のポリシー | `boundary.json` |

保存する前に、置き換えるところが四つある。

- `<アカウントID>` を自分の AWS アカウント ID にする
- `ap-northeast-1` を、そのスタックの `aws:region` と同じリージョンにする
- 信頼ポリシーの `repo:limit7412/VRCServiceStatusPanel` と `repo:limit7412@19320218/VRCServiceStatusPanel@1346007387` を、自分の `owner/repo` と数値 ID にする
- `arn:aws:` を、出す先のパーティションにする（`aws-cn`、`aws-us-gov`）

パーティションは商用の `aws` のままでよいことがほとんどである。
`infra/src/roles.ts` は境界の ARN を組むときに `aws.getPartition()` から取るので、
そちらは書き換えなくても揃う。

置き換え忘れはどれも実行時まで表に出ない。
リージョンがずれていれば CI の `CreateFunction` が `AccessDenied` になり、
リポジトリがずれていれば `configure-aws-credentials` が
`Not authorized to perform sts:AssumeRoleWithWebIdentity` で止まる。

順番は、プロバイダ、境界、ロール、ロールのポリシーになる。
信頼ポリシーがプロバイダの ARN を、デプロイポリシーが境界の ARN を参照するので、
参照される側から作る。

**1. OIDC プロバイダ。** まず在るかどうかを見る。

```
aws iam list-open-id-connect-providers
```

`token.actions.githubusercontent.com` で終わる ARN が出れば、それを使う。作らない。
アカウントに一つしか置けず、他のリポジトリも使っている可能性がある。

出なければ作る。

```
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

飛ばすと、次の `create-role` が信頼ポリシーの `Principal` を解決できず
`Invalid principal` で止まる。

**2. 権限境界。**

```
aws iam create-policy \
  --policy-name qazx7412-vrc-service-status-panel-workload-boundary \
  --policy-document file://boundary.json
```

**3. デプロイロール。**

```
aws iam create-role \
  --role-name qazx7412-vrc-service-status-panel-github-deploy \
  --description "Deploy role for GitHub Actions in limit7412/VRCServiceStatusPanel" \
  --assume-role-policy-document file://trust.json
```

`--description` に日本語は入らない。
IAM はここを Latin-1 の範囲に限っており、外れると `ValidationError` で止まる。

**4. ロールのポリシー。**

```
aws iam put-role-policy \
  --role-name qazx7412-vrc-service-status-panel-github-deploy \
  --policy-name deploy \
  --policy-document file://deploy-policy.json
```

### 権限を変えるとき

`deploy-policy.json` を直して `put-role-policy` を流し直す。
インラインポリシーなので版は残らず、そのまま置き換わる。

信頼ポリシー（引ける相手）を変えるときは `update-assume-role-policy` を使う。

```
aws iam update-assume-role-policy \
  --role-name qazx7412-vrc-service-status-panel-github-deploy \
  --policy-document file://trust.json
```

境界を変えるときは新しい版を作って既定にする。
`DenyBoundaryEdit` があるので、CI からは通らない。

**先に空きを作る。** 管理ポリシーは版を五つまでしか持てず、埋まっていると
`create-policy-version` が `LimitExceeded` で止まる。

既定の版も一つと数える。数えるほうは既定を含めて出す。

```
aws iam list-policy-versions \
  --policy-arn arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary \
  --query 'Versions[].[VersionId,IsDefaultVersion,CreateDate]' --output text
```

五行あれば上限である。消す相手は `IsDefaultVersion` が `False` の行から選ぶ。
既定の版は消せないので、そこを外していちばん古いものを消す。

```
aws iam delete-policy-version \
  --policy-arn arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary \
  --version-id v2
```

空きができたら新しい版を作る。

```
aws iam create-policy-version \
  --policy-arn arn:aws:iam::<アカウントID>:policy/qazx7412-vrc-service-status-panel-workload-boundary \
  --policy-document file://boundary.json \
  --set-as-default
```

**直したら、この文書の JSON も同じ内容に揃える。** ここが実物の記録であり、
ずれると次に作り直すときに違うものが出来上がる。

## リポジトリ側に入れるもの

GitHub の Secrets に `AWS_DEPLOY_ROLE_ARN` としてロールの ARN を登録する。

```
gh secret set AWS_DEPLOY_ROLE_ARN
```

境界は Secrets ではなく Pulumi の設定に入れる。入れるのは名前だけである。

```
pulumi -C infra config set --stack <スタック名> workloadBoundaryName \
  qazx7412-vrc-service-status-panel-workload-boundary
```

`infra/init-stack.sh` を流すなら、この設定も聞かれる。
アカウントに境界が実在するときだけ既定として出るので、Enter で通せばよい。

ワークフローでの受け取り方は `infra/README.md` の「ワークフローでの受け取り」にある。
`permissions` に `id-token: write` を入れないと、OIDC のトークンがそもそも発行されない。

## Pulumi に載せない理由

CI の権限を決める場所を、その CI が流すプログラムに置くと、CI が自分の権限を書き換えられる。
`DenySelfEscalation` でそれは塞げるが、塞いだぶん Pulumi は自分の定義を適用できなくなり、
このロールに触れる変更を出すたびに CI が `AccessDenied` で止まる。
別プログラムに分けても、置き場所と設定とパスフレーズが要る点は変わらない。

OIDC プロバイダの側にも事情がある。
アカウントに一つしかない共有資源で、他のリポジトリも使っている可能性がある。
`pulumi destroy` の射程に入れると、このプロジェクトを畳んだだけで無関係の CI が止まる。

作るのは一度きりで、変えるのも年に数えるほどである。
差分を見続ける値打ちが無いので、CLI で作ってここに記録する形にした。
