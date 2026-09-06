# リリースの流れ

ワールド側アセット（VPM パッケージ）と集約サーバーを、どの契機で、どこへ出すか。
仕様書 9.2 が決めた形を、ワークフローとして置いてある。

出るものと契機は二つに限る。

| 契機 | 出るもの |
| --- | --- |
| `master` へのマージ | VPM のプレリリース（test 版）、`dev` スタックへのデプロイ |
| リリースの公開（正式版） | VPM の正式版パッケージ、`prod` スタックへのデプロイ |

## ワークフローの一覧

| ファイル | 起動 | 何をするか |
| --- | --- | --- |
| `prerelease.yml` | `master` への push、手動 | パッケージの中身に触れた取り込みで、`X.Y.Z-testN` のタグとプレリリースを作り、zip を添付し、リスティングへ通知する |
| `deploy-dev.yml` | `master` への push | 集約サーバーか配信経路に触れた取り込みで、`deploy.yml` を `dev` へ向けて呼ぶ |
| `release.yml` | リリースの公開（`published`）、手動 | zip を作ってリリースへ添付し、リスティングへ通知する。手動では zip を artifact に置くだけ |
| `deploy-prod.yml` | リリースの公開（`released`） | タグのコミットが `master` に含まれることを確かめ、`deploy.yml` を `prod` へ向けて呼ぶ |
| `deploy.yml` | 上の二つからの呼び出し、手動 | `pulumi up`。手動では出す先を入力で選ぶ |

`prerelease.yml` と `deploy-dev.yml` は同じ push で並んで走るが、互いに `needs` で繋いでいない。
繋ぐと、`dev` デプロイが落ちた日にプレリリースも作られなくなる。

どちらも `on` の `paths` ではなく、`.github/actions/changed-paths` で対象を絞る。
判定できなかった変更は、作る側、出す側へ倒す。
`prerelease.yml` の対象は zip に入るもの（`package.json`、`Runtime/`、`Editor/` と、それらの `.meta`）に揃えてあり、`Tests/` は含まない。
`deploy-dev.yml` の対象は `backend/`、`infra/`、`deploy.yml` とそのワークフロー自身である。

## 版とタグ

タグは `X.Y.Z` の形にする。
`v` は付けない。
`prerelease.yml` は `X.Y.Z` に合うタグだけを安定版として数え、`v0.1.0` のようなタグは起点にならない。

プレリリースの版は、最新の安定版タグからパッチを一つ上げた `X.Y.(Z+1)` に `-testN` を付けたものになる。
同じ次期バージョンの `-testN` が既にあれば N を一つ進める。
パッチ以外（マイナー、メジャー）を上げたいプレリリースは、GitHub の Releases で `X.Y.Z-testN` のタグを手で打ち、プレリリースとして公開する。
`release.yml` が zip を付け、リスティングへ通知する。

安定版タグが一つも無いあいだは、`0.1.0` を次期バージョンとして `0.1.0-testN` を作る。
最初の安定版を `0.1.0` と決めてあるためで（仕様書 9.2）、この値は `prerelease.yml` の `FIRST_VERSION` にある。
`0.1.0` を打った後は使われない。

`package.json` の `version` はリリース時にタグから上書きする。
`master` 上の値は起点に使わないので、取り込みのたびに上げなくてよい。

## 正式版を出す手順

1. `master` の先端にあることを確かめる。`deploy-prod.yml` はタグのコミットが `master` に含まれないと止まる
2. GitHub の Releases で、`X.Y.Z` のタグを `master` に打ち、リリースを公開する
3. `release.yml` が zip を添付し、リスティングへ通知する
4. `deploy-prod.yml` が `prod` へ出す

プレリリースを正式版へ昇格した場合も、4 は動く。
昇格では `released` だけが発火し、`published` は発火しないので、3 は動かない。
zip は昇格前に添付済みで、リスティングは vcc-vpm 側の "Build Repo Listing" を手で流せば作り直せる。

集約サーバーだけを出したいときと、前のタグへ切り戻すときは、`deploy.yml` を手で流す。
Actions の deploy を `workflow_dispatch` で開き、ref とスタックを選ぶ。

## 手で行う作業

**VPM リスティングへ本リポジトリを足す。**
リスティングは `limit7412/vcc-vpm` にあり、`source.json` の `githubRepos` に並んだリポジトリのリリースから索引を作る。
そこへ `limit7412/VRCServiceStatusPanel` を足す。

**`LISTING_DISPATCH_TOKEN` を Secrets へ置く。**
`vcc-vpm` だけをスコープとし Contents の読み書きを持つ fine-grained PAT を作り、本リポジトリの Secrets に `LISTING_DISPATCH_TOKEN` として置く。
本リポジトリの `GITHUB_TOKEN` は他リポジトリへ届かないため、通知にはこれが要る。
置くまでのあいだ、`prerelease.yml` と `release.yml` は通知を飛ばして notice を出す。プレリリースと zip の添付は置かなくても動く。

**OIDC の信頼設定にタグの ref を足す。**
`release` イベントで動くワークフローが受け取る OIDC トークンの `sub` は `ref:refs/tags/<タグ>` になる。
AWS の信頼ポリシーと Pulumi Cloud の認可ポリシーは `ref:refs/heads/master` だけを通していたので、どちらにも `ref:refs/tags/*` を足す。
足さないと `deploy-prod.yml` は AWS にも Pulumi Cloud にも入れない。
手順は `docs/aws-oidc.md` の「誰がロールを引けるか」と、`infra/README.md` の「手で行う作業」にある。

**`master` のブランチ保護。**
`deploy-dev.yml` は検査の成功を前提にしていない。
`backend-ci` と `unity-test` は同じ push で並んで走るだけで、required status check で pull request を縛っていなければ、未検証の内容が `dev` に出る。
