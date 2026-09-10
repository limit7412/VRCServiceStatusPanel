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
| `deploy.yml` | `deploy-dev.yml` と `release.yml` からの起動、手動。どれも `workflow_dispatch` | `pulumi up`。ジョブは出す先と同じ名前の environment を参照する。手動では出す先を入力で選ぶ |

`prerelease.yml` と `deploy-dev.yml` は同じ push で並んで走るが、互いに `needs` で繋いでいない。
繋ぐと、`dev` デプロイが落ちた日にプレリリースも作られなくなる。

どちらも `on` の `paths` ではなく、`.github/actions/changed-paths` で対象を絞る。
判定できなかった変更は、作る側、出す側へ倒す。
`prerelease.yml` の対象は zip に入るもの（`package.json`、`Runtime/`、`Editor/` と、それらの `.meta`）に揃えてあり、`Tests/` は含まない。
`deploy-dev.yml` の対象は `backend/`、`infra/`、`deploy.yml` とそのワークフロー自身である。
force push のときは差分に巻き戻した分が出ないので、どちらも対象に触れたものとして動く。

## 版とタグ

タグは `X.Y.Z` の形にする。
`v` は付けない。
数は 0 か、0 で始まらない十進数に限る（`0.1.08` は通らない）。
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
`deploy-dev.yml` は `deploy.yml` を `master` の ref で起こすので、手順の定義も先端のものになる。
手で流すときも同じで、どの ref を選んでも `master` の先端から作る。

先端に既にプレリリースのタグがあれば、`prerelease.yml` は新しい版を作らず、その版で足りないもの（zip の添付、リスティングへの通知）だけを続ける。
タグを作った後に落ちた実行は、再実行すれば続きから進む。
実行は出すコミットと打ったタグを自分の artifact に記録し、再実行はそれを読んで、そのタグを続ける。
記録はコミットだけのものとタグまでのものに分け、名前に試行番号を入れて置き直さない。
一つの名前を上書きすると、置き直しの隙に落ちたときに記録が一つも残らない。
タグを記録する前に落ちていて、そのコミットにタグが二つ以上あれば、どれを続けるか決められないので止まる。
続ける版に zip が無ければ、先端で決め直して同じ版が出ることを確かめる。
出なければ公開済みの最新より古い版で、リリースが無ければ作りかけのタグとして消して先端から決め直し、リリースがあれば止まる。
再実行までに `master` が進み、別の実行が次の版を出していても、そのタグに zip が無ければ、その内容で zip を作って付ける。
タグを作る前に落ちていれば、再実行は先端から版を決め直す。

次の版の計算は、`master` から辿れて、zip の付いたリリースのあるタグだけを見る。
別のブランチや `master` の過去のコミットに打って公開を拒まれたタグが残っても、採番はそれで飛ばない。
人が公開したリリース（正式版と、系列を始めるために手で作った `X.Y.Z-testN`）の zip は `release.yml` が公開の後で付ける。
zip の無いリリースがあれば、その `release.yml` の build が終わるまで待ってから数える。
待たずに数えると、そのリリースより古い版が後から出る。
build がタグの検査で落ちたリリースは、拒まれたものとして数えない。
検査の後で落ちたリリースがあると、直すか消すまで採番は止まる。
新しく決めた版は、zip を作った後にもう一度決め直し、変わっていれば zip を作り直してから、タグを打ち、リリースを作って zip を付ける。
ここまでを一つのステップで行い、あいだに他のステップを挟まない。
公開した後にもう一度決め直し、同じ版が出れば確定し、違えば作ったリリースとタグを消してやり直す。
決めてから公開までのあいだに正式版が出ると、決めた版はその正式版より古くなるので、その窓を一つのステップの中に閉じている。

リリースの有無は `release-json.sh` で見る。
`gh` の終了コードは、リリースが無いときも通信や認証で失敗したときも 1 になるので、標準エラーの HTTP 404 で分ける。
分けないと、照会が失敗しただけで「無い」と読み、人が公開したリリースのタグを作りかけとして消す。
下書きのリリースが残っていれば、人が作ったものとして触らずに止まる。

zip を作る `build-package.sh` は、資産と `.meta` が対になっていること、シンボリックリンクが無いことを確かめてから固める。
配下の `.meta` が欠けると入れた側で GUID が振り直され、アセンブリ資産の参照が切れる。
シンボリックリンクは `zip -r` が参照先を辿るので、パッケージの外を指すものがあると、その中身が公開される。

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
`workflow_call` で呼ばないのは二つの理由による。
リリースの公開で動く実行はタグの ref を持ち、`deploy.yml` のジョブが参照する environment `prod` の規則（`master` だけ）に当たる。
呼ばれたワークフローは呼んだ側のコミットの定義で動くので、実行の順序が入れ替わると古い定義で出すことがある。
`master` の ref で起こせば規則に当たらず、定義も内容も先端になり、出るのも `master` の内容に限られる。
`deploy-dev.yml` も同じ理由で同じ形をとる。
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
承認待ちに入ると、起こした側の `release.yml` はそこで待つのをやめ、承認後の結果は `deploy.yml` の実行で見る。
ジョブは六時間で打ち切られるので、承認が遅れたときに `release.yml` だけが失敗して食い違うことを避けている。

**OIDC の信頼設定を environment に変える。**
environment を参照するジョブが受け取る OIDC トークンの `sub` は `environment:<名前>` になり、ブランチもタグも含まない。
AWS の信頼ポリシーと Pulumi Cloud の認可ポリシーは `ref:refs/heads/master` を通していたので、どちらも `environment:dev` と `environment:prod`（新旧の形で四つ）にする。
移行は二段で行う。
まず `master` の ref の二つを残したまま environment の四つを足し、environment を参照するワークフローを `master` へ入れる。
`dev` デプロイが通ったら、`master` の ref の二つを消す。
先に消すと、それまでの `master` の ref で動く `deploy.yml` が入れずに止まる。
手順は `docs/aws-oidc.md` の「誰がロールを引けるか」と、`infra/README.md` の「手で行う作業」にある。

ref ではなく environment で絞るのは、タグの ref を `*` で通す形だと、write 権限を持つ者が任意のブランチにタグを打って `deploy.yml` を手で流すだけでロールを引けるためである。
`master` のブランチ保護を経ない経路が一つ増える。
environment なら、どの ref からその名前を名乗れるかを GitHub 側の規則が決め、ロールから見える条件は名前だけになる。

**`master` のブランチ保護。**
`deploy-dev.yml` は検査の成功を前提にしていない。
`backend-ci` と `unity-test` は同じ push で並んで走るだけで、required status check で pull request を縛っていなければ、未検証の内容が `dev` に出る。
