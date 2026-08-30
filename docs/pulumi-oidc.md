# GitHub Actions から Pulumi Cloud へ入る

CI が state を読み書きするための入口。
OIDC で短命のアクセストークンを受け取るので、`PULUMI_ACCESS_TOKEN` を Secrets へ置かずに済む。

**ここに書いたものは Pulumi で管理していない。** Pulumi Cloud の API で作り、この文書に記録してある。
理由は最後の「Pulumi に載せない理由」にある。

AWS 側の入口は `docs/aws-oidc.md` にある。

## 作ってあるもの

組織 `limit7412` に issuer を一つと、その認可ポリシーを二つ置いてある。

| 何 | 値 |
| --- | --- |
| issuer の名前 | `github-actions` |
| issuer の URL | `https://token.actions.githubusercontent.com` |
| ポリシーの数 | 2（どちらも `allow`） |

issuer の ID は API を叩くたびに要る。ここには書かず、そのつど引く。

```
curl -sS -H "Authorization: token $PULUMI_ACCESS_TOKEN" \
  https://api.pulumi.com/api/orgs/limit7412/oidc/issuers
```

登録した直後は、どのトークン交換も拒む `deny` のポリシーが一つだけ入っている。
これを差し替えないと、`pulumi/auth-actions` は 400 で止まる。

## 誰がトークンを交換できるか

`sub` でリポジトリを、`aud` で組織を絞っている。

```json
{
  "policies": [
    {
      "decision": "allow",
      "tokenType": "personal",
      "userLogin": "limit7412",
      "authorizedPermissions": null,
      "rules": {
        "aud": "urn:pulumi:org:limit7412",
        "sub": "repo:limit7412@19320218/VRCServiceStatusPanel@1346007387:*"
      }
    },
    {
      "decision": "allow",
      "tokenType": "personal",
      "userLogin": "limit7412",
      "authorizedPermissions": null,
      "rules": {
        "aud": "urn:pulumi:org:limit7412",
        "sub": "repo:limit7412/VRCServiceStatusPanel:*"
      }
    }
  ]
}
```

`tokenType` が `personal` なのは、無料の Individual で使えるのがこれだけだからである。
`userLogin` には自分のユーザー名が要る。
`authorizedPermissions` は組織トークン向けの項目なので、ここでは渡していない。

`sub` が二つ並んでいる事情は AWS 側と同じである。
GitHub が出すトークンの `sub` は、所有者とリポジトリの数値 ID を含む形へ移っている
（`docs/aws-oidc.md` の「誰がロールを引けるか」）。
新しい形と古い形の両方を並べてある。

AWS 側と違い、末尾は `:*` にしてある。
ref を絞っていないので、`master` 以外の枝から流したワークフローでもトークンを交換できる。
state に手が届くのは AWS の資格情報を持つ `master` の実行だけなので、ここは緩めてある。
`master` に揃えるなら、末尾を `:ref:refs/heads/master` にする。

## 作り直すとき

Pulumi Cloud の Settings、Access Management、OIDC Issuers から登録できる。
API で流すなら次の二つになる。
`$PULUMI_ACCESS_TOKEN` には自分のアカウントのトークンを入れる（`pulumi login` した手元なら
`~/.pulumi/credentials.json` にある）。

**1. issuer を登録する。**

```
curl -sS -X POST -H "Authorization: token $PULUMI_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"github-actions","url":"https://token.actions.githubusercontent.com"}' \
  https://api.pulumi.com/api/orgs/limit7412/oidc/issuers
```

返る `id` を次で使う。

**2. 認可ポリシーを差し替える。**

ポリシーの ID は issuer の ID から引く。

```
curl -sS -H "Authorization: token $PULUMI_ACCESS_TOKEN" \
  https://api.pulumi.com/api/orgs/limit7412/auth/policies/oidcissuers/<issuer の ID>
```

上の JSON を `policies.json` に保存して投げる。

```
curl -sS -X PATCH -H "Authorization: token $PULUMI_ACCESS_TOKEN" \
  -H "Content-Type: application/json" -d @policies.json \
  https://api.pulumi.com/api/orgs/limit7412/auth/policies/<ポリシーの ID>
```

`sub` に空文字を含むポリシー（登録直後の `deny` がこれである）は投げ返せない。
差し替えるときは、その一つを外した形で送る。

**fork したなら三つを自分のものに書き換える。**
`limit7412` を自分の組織とユーザー名に、`sub` の `owner/repo` と数値 ID を自分のリポジトリにする。
ワークフローの `pulumi/auth-actions` に渡す `organization` と `scope` も揃える
（`infra/README.md` の「ワークフローでの受け取り」）。
数値 ID は次で引ける。

```
gh api /repos/<owner>/<repo> --jq '"\(.owner.id) \(.id)"'
```

## Pulumi に載せない理由

`pulumiservice` プロバイダには `OidcIssuer` がある。
それでも手で作っているのは、これが CI から Pulumi Cloud へ入るための入口そのものだからである。
Pulumi で管理すると、入口を作るために入口が要る。

作るのは一度きりで、変えるのはリポジトリを移すときくらいである。
AWS 側の入口を CLI で作って `docs/aws-oidc.md` に記録してあるのと、同じ形にしてある。
