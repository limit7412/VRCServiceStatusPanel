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
| `prerelease.yml` | `master` への push、手動 | パッケージの中身に触れた取り込みで、その時点の `master` の先端から `X.Y.Z-testN` のタグとプレリリースを作り、zip を添付し、リスティングへ通知する |
| `deploy-dev.yml` | `master` への push | 集約サーバーか配信経路に触れた取り込みで、`deploy.yml` を `dev` へ向けて呼び、その時点の `master` の先端を出す |
| `release.yml` | リリースの公開（`published`）、手動 | タグを確かめてから zip を作り、リリースへ添付し、リスティングへ通知する。正式版なら `deploy.yml` を `prod` へ向けて起こし、終わるまで待つ。手動では zip を artifact に置くだけ |
| `deploy.yml` | `deploy-dev.yml` からの呼び出し、`release.yml` からの起動、手動 | `pulumi up`。ジョブは出す先と同じ名前の environment を参照する。手動では出す先を入力で選ぶ |

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
パッチ以外（マイナー、メジャー）を上げたいプレリリースは、GitHub の Releases で `X.Y.Z-testN` のタグを `master` の先端に手で打ち、プレリリースとして公開する。
`release.yml` が zip を付け、リスティングへ通知する。
以後の取り込みはその系列を継ぐ。
安定版が `0.1.0` のまま `0.2.0-test1` を手で作れば、次の取り込みは `0.1.1-test1` ではなく `0.2.0-test2` になる。
計算は `.github/scripts/next-prerelease-version.sh` にある。

安定版タグが一つも無いあいだは、`0.1.0` を次期バージョンとして `0.1.0-testN` を作る。
最初の安定版を `0.1.0` と決めてあるためで（仕様書 9.2）、この値は `prerelease.yml` の `FIRST_VERSION` にある。
`0.1.0` を打った後は使われない。

`package.json` の `version` はリリース時にタグから上書きする。
`master` 上の値は起点に使わないので、取り込みのたびに上げなくてよい。

`prerelease.yml` も `deploy-dev.yml` も、push されたコミットではなく、走った時点の `master` の先端を使う。
concurrency の群の中で実行の順序は保証されず、先の push の実行が後から走ることがある。
push されたコミットで作ると、後の push の内容を出した後に古い内容が最大の版として積まれる。
先端を使えば、順序が入れ替わっても古い内容へ戻らない。
先端に既にプレリリースのタグがあれば、`prerelease.yml` は作らずに終わる。
手で流すときも同じで、どの ref を選んでも `master` の先端から作る。

次の版の計算は `master` から辿れるタグだけを見る。
別のブランチに打って公開を拒まれたタグが残っても、採番はそれで飛ばない。

## 正式版を出す手順

1. GitHub の Releases で、`X.Y.Z` のタグを `master` の先端に打ち、リリースを公開する
2. `release.yml` がタグを確かめ、zip を添付し、リスティングへ通知し、`prod` へ出す

タグの検査は `.github/scripts/verify-release-tag.sh` で行い、形と、タグのコミットが `master` の先端であることを見る。
形は、正式版（プレリリースでない公開）が `X.Y.Z`、プレリリースが `X.Y.Z-testN` である。
先端でなければ止まり、zip も添付しない。
過去の `master` のコミットに打ったタグも通さない。
祖先であることだけを見ると、古いコミットからのリリースで `prod` がその時点へ巻き戻る。
公開の直後に別の取り込みが入って先端がずれたときは、リリースを消してタグを打ち直す。

`prod` へ出すのは zip の添付が通ってからで、`release.yml` が `deploy.yml` を `master` の ref で `workflow_dispatch` として起こし、終わるまで待つ。
`workflow_call` で呼ばないのは、リリースの公開で動く実行がタグの ref を持ち、`deploy.yml` のジョブが参照する environment `prod` の規則（`master` だけ）に当たるためである。
`master` の ref で起こせば規則に当たらず、出るのも `master` の内容に限られる。
タグのコミットを `expected_sha` で渡し、`deploy.yml` が checkout したものと比べるので、起こしてから `master` が進んでいれば止まる。
起こした実行が成功で終わらなければ、`release.yml` も失敗になる。

プレリリースを正式版へ昇格する経路は使わない。
昇格ではタグ名が `X.Y.Z-testN` のまま変わらず、正式版の形に合わない。
仕様書 9.2 は昇格でも `prod` へ出す形（`released` を契機にする）を挙げていたが、この理由で採らない。
昇格しても `released` しか発火せず、それを購読するワークフローは無いので、何も起きない。
正式版は必ず新しい `X.Y.Z` のタグで公開する。

集約サーバーだけを出したいときは、`deploy.yml` を手で流す。
Actions の deploy を `workflow_dispatch` で開き、ref に `master` を選び、スタックを選ぶ。
environment の規則が `master` だけを許すので、他の ref からは起動できない。

前のタグへ切り戻すときも ref は `master` のまま、`ref` の入力に戻したいタグを入れる。
`deploy.yml` はその内容を checkout し、`master` に含まれるコミットであることを確かめてから出す。
`master` に入って `dev` で試したものしか出せない。

## 手で行う作業

**VPM リスティングへ本リポジトリを足す。**
リスティングは `limit7412/vcc-vpm` にあり、`source.json` の `githubRepos` に並んだリポジトリのリリースから索引を作る。
そこへ `limit7412/VRCServiceStatusPanel` を足す。

**`LISTING_DISPATCH_TOKEN` を Secrets へ置く。**
`vcc-vpm` だけをスコープとし Contents の読み書きを持つ fine-grained PAT を作り、本リポジトリの Secrets に `LISTING_DISPATCH_TOKEN` として置く。
本リポジトリの `GITHUB_TOKEN` は他リポジトリへ届かないため、通知にはこれが要る。
置くまでのあいだ、`prerelease.yml` と `release.yml` は通知を飛ばして notice を出す。プレリリースと zip の添付は置かなくても動く。

**environment `dev` と `prod` を作り、規則を置く。**
`deploy.yml` のジョブは出す先と同じ名前の environment を参照する。
存在しない environment を参照して動かすと、保護規則の無い environment が自動で作られるので、先に admin が作って規則を置く。
Settings の Environments で、それぞれ Deployment branches and tags を「Selected branches and tags」にし、次を許す。

| environment | 許す ref |
| --- | --- |
| `dev` | ブランチ `master` |
| `prod` | ブランチ `master` |

どちらもタグを許さない。
`prod` へ出す `release.yml` はリリースの公開（タグの ref）で動くが、`deploy.yml` を `master` の ref で起こすので、タグから `prod` を名乗る必要が無い。
タグを許すと、write 権限を持つ者が未レビューのコミットに `X.Y.Z` の形のタグを打ち、その ref で `deploy.yml` を手で流すだけで `prod` を名乗れる。
`master` だけなら、出る内容は `master` に限られ、`master` に入るものはブランチ保護が決める。
さらに絞るなら `prod` に required reviewers を掛ける。
ジョブは承認を待つあいだトークンを受け取らず、承認した実行だけが `prod` を名乗れる。

**OIDC の信頼設定を environment に変える。**
environment を参照するジョブが受け取る OIDC トークンの `sub` は `environment:<名前>` になり、ブランチもタグも含まない。
AWS の信頼ポリシーと Pulumi Cloud の認可ポリシーは `ref:refs/heads/master` を通していたので、どちらも `environment:dev` と `environment:prod`（新旧の形で四つ）に差し替える。
順序は、先に信頼設定を差し替え、次に environment を参照するワークフローを `master` へ入れる。
逆にすると、そのあいだの `dev` デプロイが入れずに止まる。
手順は `docs/aws-oidc.md` の「誰がロールを引けるか」と、`infra/README.md` の「手で行う作業」にある。

ref ではなく environment で絞るのは、タグの ref を `*` で通す形だと、write 権限を持つ者が任意のブランチにタグを打って `deploy.yml` を手で流すだけでロールを引けるためである。
`master` のブランチ保護を経ない経路が一つ増える。
environment なら、どの ref からその名前を名乗れるかを GitHub 側の規則が決め、ロールから見える条件は名前だけになる。

**`master` のブランチ保護。**
`deploy-dev.yml` は検査の成功を前提にしていない。
`backend-ci` と `unity-test` は同じ push で並んで走るだけで、required status check で pull request を縛っていなければ、未検証の内容が `dev` に出る。
