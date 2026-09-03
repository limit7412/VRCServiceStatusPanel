require "log"
require "../upstream"
require "./models"

# VRChat が同梱している yt-dlp の版を返す（仕様書 7.3）。
#
# Layer に載せた版と食い違っていれば、YouTube の note にそれを出す。
# 検査に使う版が VRChat と違えば、こちらで再生できても向こうで再生できない
# 期間ができる。その食い違いに気付くための経路である。
#
# 認証は要らない。`/config` は非公式の OpenAPI 定義で `security: []` になっている。
module VrchatApi
  class Repository
    Log = ::Log.for("vrchat_api")

    CONFIG_URL = "https://api.vrchat.cloud/api/1/config"

    # 取りに行く間隔。
    #
    # 仕様書 7.3 は「実行ごと」だが、VRChat API のライブラリは「once per 60 seconds」
    # を上限とし、FAQ は「Cache aggressively」と言っている。60 秒間隔の関数から
    # 毎回叩くと、Scheduler の揺らぎで上限を切る。
    # 版が変わるのは VRChat クライアントの更新時だけなので、一時間に一度で足りる。
    #
    # 最後に取った時刻はインスタンスが持つ。コールドスタートで忘れて一度余分に
    # 取るが、それは日に数回である。BOOTH のお知らせと同じ扱いになる。
    INTERVAL = 1.hour

    @version : String?
    @fetched_at : Time?

    # endpoint を受け取るのは spec から差し替えるためである。
    def initialize(@endpoint : String = CONFIG_URL)
    end

    # 同梱版の版。取れなければ nil。
    #
    # now を引数で受けるのは、間隔の境界を spec から確かめるためである。
    #
    # 取り直しに失敗したときは前回の値を残す。
    # 版が変わるのは稀で、取れなかった一時間だけ照合が消えるより、
    # 古い版で比べ続けるほうが読み手を惑わせない。
    # ただし次の一時間まで取り直さないのは、失敗のときも同じである。
    # 毎分試しても届かず、届かなかったことのログだけが増える。
    def version(now : Time = Time.utc) : String?
      return @version unless due?(now)

      @fetched_at = now
      fetched = fetch
      @version = fetched unless fetched.nil?

      @version
    end

    private def due?(now : Time) : Bool
      last = @fetched_at

      last.nil? || now - last >= INTERVAL
    end

    # 例外を出さない。照合できなかったことは YouTube の状態ではないので、
    # ここで漏らすと、その実行の YouTube ごと落とすことになる。
    private def fetch : String?
      response = Upstream.get(@endpoint)

      unless response.status_code == 200
        Log.warn { "/config が応答しない（HTTP #{response.status_code}）" }
        return
      end

      Config.from_json(response.body).player_url_resolver_version
    rescue error
      Log.warn(exception: error) { "/config を読めない" }
      nil
    end
  end
end
