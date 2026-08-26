require "./config"
require "./runtime/lambda"
require "./status/models"

# 構成ルート（仕様書 11.2、11.7）。
# コールドスタート時に一度だけ環境変数を解決し、依存を組み立てる。
#
# 関数は `_HANDLER` で振り分ける。同じバイナリを複数の関数で使い回すための形で、
# 参考リポジトリ（limit7412/github_notifications_slack）と同じである。
# 関数を増やすときは、ここへ handler を足し、HANDLERS と infra/index.ts の
# FUNCTIONS にも同じ名前を足す。
#
# 取得元のアダプタは statuspage だけがある。observe を呼ぶ Usecase#refresh と、
# 書き出し先の r2 がまだ無いため、いまの refresh は空の Feed を返すだけで、
# R2 へは書かない。デプロイの経路と Runtime API のやり取りを先に通すための形である。

HANDLERS = %w[refresh]

Runtime::Lambda.setup_log
Runtime::Lambda.setup_ssl_cert

config = begin
  Main::Config.from(ENV.to_h)
rescue ex
  Runtime::Lambda.fail_to_start(ex)
end

Log.info { "起動した handler=#{Runtime::Lambda.handler_name} #{config.to_log}" }

Runtime::Lambda.handler "refresh" do |_event|
  # 観測がまだ無いので、サービスの並びは空になる。
  # 上流をひとつも取れていない状態なので stale を真にする（仕様書 4）。
  feed = Status::Feed.new(
    generated_at: Time.utc,
    stale: true,
    services: [] of Status::ServiceStatus,
  )

  Log.info { "feed を組み立てた generated_unix=#{feed.generated_unix}" }

  feed
end

# ここへ到達するのは `_HANDLER` がどの handler とも一致しなかったときである。
Runtime::Lambda.reject_unknown_handler(HANDLERS)
