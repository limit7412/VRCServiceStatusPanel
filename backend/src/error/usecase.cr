require "http/client"
require "json"
require "log"
require "uri"

# 失敗の通知（仕様書 11.2、11.7）。
#
# handler は refresh の例外をここへ渡してから再送出する。
# 再送出するので、Runtime API へはその起動の失敗として報告される。
# ここが担うのは、人へ届ける経路だけである。
module Error
  class Usecase
    Log = ::Log.for("error")

    # 送信の上限。
    # 上流への GET と揃える理由は無いが、待ち続けても実行の残り時間を
    # 食うだけなので、同じ 5 秒で諦める。
    TIMEOUT = 5.seconds

    # 同じ種類の失敗を送る間隔。
    #
    # 60 秒ごとに同じ原因で落ちると、通知も 60 秒ごとに届く。
    # 一通目で分かることは二通目には無く、届き続けると読まれなくなる。
    #
    # 最後に送った時刻はインスタンスが持つので、コールドスタートで忘れる。
    # そのときは一通余分に届く。
    INTERVAL = 10.minutes

    def initialize(@env : String, @webhook_url : String)
      @last_sent = {} of String => Time
    end

    # 失敗を一件送る。
    #
    # 抑えたことは記録しない。失敗そのものは runtime が毎回記録しており、
    # 通知が来ないあいだも、ログを見れば続いていることが分かる。
    def alert(handler : String, error : Exception, request_id : String?, now : Time? = nil) : Nil
      at = now || Time.utc
      kind = error.class.name

      return unless due?(kind, at)

      # 送れたかによらず、試みた時点で数える。
      # 送れないものは 10 分後にもたぶん送れない。
      # 毎分試しても届かず、届かなかったことのログだけが増える。
      @last_sent[kind] = at

      post(body(handler, error, kind, request_id))
    end

    private def due?(kind : String, at : Time) : Bool
      last = @last_sent[kind]?

      last.nil? || at - last >= INTERVAL
    end

    # 仕様書 11.7 の五つ。
    private def body(handler : String, error : Exception, kind : String, request_id : String?) : String
      {
        env:        @env,
        handler:    handler,
        error_type: kind,
        message:    error.message.to_s,
        request_id: request_id,
      }.to_json
    end

    private def post(body : String) : Nil
      uri = URI.parse(@webhook_url)

      client = HTTP::Client.new(uri)
      client.connect_timeout = TIMEOUT
      client.read_timeout = TIMEOUT

      response = begin
        client.post(
          request_target(uri),
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: body,
        )
      ensure
        client.close
      end

      return if response.success?

      Log.error { "アラートが受け取られなかった HTTP #{response.status_code}" }
    rescue error
      # 送れなくても、失敗そのものは runtime が記録して Lambda へ報告する。
      # 伝える手立てが一つ欠けるだけなので、ここで例外を出さない。
      # 出せば、本体の失敗の報告がアラートの失敗に置き換わる。
      Log.error(exception: error) { "アラートを送れなかった" }
    end

    private def request_target(uri : URI) : String
      target = uri.request_target

      target.empty? ? "/" : target
    end
  end
end
