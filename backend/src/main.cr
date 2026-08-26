require "./config"
require "./runtime/lambda"
require "./status/models"

# 構成ルート（仕様書 11.2、11.7）。
# コールドスタート時に一度だけ環境変数を解決し、依存を組み立てる。
#
# 取得元のアダプタ（仕様書 11.2 の statuspage、youtube、steam、booth、r2）は
# まだ無い。いまのハンドラは空の Feed を返すだけで、R2 へは書かない。
# デプロイの経路と Runtime API のやり取りを先に通すための形である。

Runtime::Lambda.setup_log
Runtime::Lambda.setup_ssl_cert

begin
  lambda = Runtime::Lambda.from_env
rescue ex : Runtime::Lambda::NotOnLambda
  # 手元で直接叩いたとき。報告先が無いので記録だけして終わる。
  Log.error { ex.message }
  exit 1
end

begin
  config = Main::Config.from(ENV.to_h)
rescue ex
  # 環境変数が足りないなら、起動を受ける前に落ちる（仕様書 11.7）。
  # 起動を受けてから落ちると、失敗が 60 秒ごとに繰り返される。
  Log.error(exception: ex) { "初期化に失敗した" }
  lambda.report_init_error(ex)
  exit 1
end

Log.info { "起動した #{config.to_log}" }

lambda.run do |_payload|
  # 観測がまだ無いので、サービスの並びは空になる。
  # 上流をひとつも取れていない状態なので stale を真にする（仕様書 4）。
  feed = Status::Feed.new(
    generated_at: Time.utc,
    stale: true,
    services: [] of Status::ServiceStatus,
  )

  Log.info { "feed を組み立てた generated_unix=#{feed.generated_unix}" }

  feed.to_json
end
