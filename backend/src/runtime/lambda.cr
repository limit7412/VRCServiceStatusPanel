require "http/client"
require "json"
require "log"
require "uri"

# Lambda の Runtime API をそのまま扱う（仕様書 11.2）。
#
# shard を挟まないのは参考リポジトリ（limit7412/github_notifications_slack）と
# 同じ方針である。やり取りは HTTP 三種だけで、依存を増やす利がない。
module Runtime
  class Lambda
    API_VERSION = "2018-06-01"

    # 静的リンクした OpenSSL は CA バンドルを自力で見つけられない（仕様書 5.1）。
    # provided.al2023 が置いている場所を起動時に教える。
    # これを忘れると、上流への HTTPS がすべて証明書エラーで失敗する。
    CA_BUNDLE = "/etc/pki/tls/cert.pem"

    REQUEST_ID_HEADER = "Lambda-Runtime-Aws-Request-Id"

    # 一回の起動で受け取るもの。
    record Invocation, request_id : String, payload : String

    # 環境変数が無い、つまり Lambda の外で動かされたとき。
    class NotOnLambda < Exception
      def initialize
        super("AWS_LAMBDA_RUNTIME_API が無い。Lambda の上でのみ動く")
      end
    end

    # CloudWatch は改行で記録を割るため、一件を一行に収める。
    def self.setup_log(level : ::Log::Severity = ::Log::Severity::Info) : Nil
      backend = ::Log::IOBackend.new(STDOUT, formatter: FORMATTER)
      ::Log.setup(level, backend)
    end

    FORMATTER = ::Log::Formatter.new do |entry, io|
      io << entry.severity.label << ' '
      io << entry.source << ' ' unless entry.source.empty?
      # 例外の内容も含めて一行に潰す。
      io << entry.message.gsub('\n', ' ')
      if ex = entry.exception
        io << " | " << ex.class << ": " << ex.message.to_s.gsub('\n', ' ')
      end
    end

    def self.setup_ssl_cert(path : String = CA_BUNDLE) : Nil
      # 呼び出し側が明示していればそちらを尊重する。
      return if ENV["SSL_CERT_FILE"]?
      return unless File.exists?(path)

      ENV["SSL_CERT_FILE"] = path
    end

    # 環境変数から組み立てる。Lambda の外では例外にする。
    def self.from_env : Lambda
      endpoint = ENV["AWS_LAMBDA_RUNTIME_API"]?
      raise NotOnLambda.new if endpoint.nil? || endpoint.empty?

      new(endpoint)
    end

    def initialize(@endpoint : String)
      @client = HTTP::Client.new(URI.parse("http://#{@endpoint}"))
      # 次の起動を待つ GET は応答が来るまで開いたままになる。
      # 読み取りに制限を掛けると、待っている間に自分から切ってしまう。
      @client.read_timeout = nil
    end

    # 起動を受けては handler へ渡す、を繰り返す。
    #
    # handler の例外はその起動の失敗として報告し、ループは続ける。
    # 一回の失敗でプロセスを終わらせると、次の 60 秒まで何も更新されない。
    def run(&handler : String -> String) : Nil
      loop do
        begin
          invocation = next_invocation
        rescue ex : IO::Error
          # Runtime API との接続が切れた。実行環境が畳まれるときに起きる。
          # 掴んでも次の起動は来ないので、記録して終わる。
          # Lambda はプロセスの終了を検知して新しい実行環境を立ち上げる。
          ::Log.error(exception: ex) { "Runtime API との接続が切れた" }
          return
        end

        begin
          respond(invocation.request_id, handler.call(invocation.payload))
        rescue ex
          ::Log.error(exception: ex) { "起動の処理に失敗した request_id=#{invocation.request_id}" }
          report_invocation_error(invocation.request_id, ex)
        end
      end
    end

    # 初期化そのものに失敗したことを伝える。
    # 報告できなくても落とさない。伝える手段が無いだけで、終わることに変わりはない。
    def report_init_error(ex : Exception) : Nil
      @client.post("/#{API_VERSION}/runtime/init/error", body: error_body(ex))
    rescue error
      ::Log.error(exception: error) { "初期化の失敗を報告できなかった" }
    end

    private def next_invocation : Invocation
      response = @client.get("/#{API_VERSION}/runtime/invocation/next")
      request_id = response.headers[REQUEST_ID_HEADER]?

      raise "#{REQUEST_ID_HEADER} が応答に無い" if request_id.nil?

      Invocation.new(request_id, response.body)
    end

    private def respond(request_id : String, body : String) : Nil
      @client.post("/#{API_VERSION}/runtime/invocation/#{request_id}/response", body: body)
    end

    private def report_invocation_error(request_id : String, ex : Exception) : Nil
      @client.post("/#{API_VERSION}/runtime/invocation/#{request_id}/error", body: error_body(ex))
    rescue error
      ::Log.error(exception: error) { "起動の失敗を報告できなかった request_id=#{request_id}" }
    end

    private def error_body(ex : Exception) : String
      {errorType: ex.class.name, errorMessage: ex.message.to_s}.to_json
    end
  end
end
