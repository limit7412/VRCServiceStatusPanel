require "uri"
require "../status/models"
require "../status/repository"
require "../upstream"
require "./models"

module Youtube
  # YouTube の合成監視（仕様書 3.3）。
  #
  # 知りたいのは「ワールドの動画プレイヤーで再生できるか」で、それは
  # サイトの稼働よりも yt-dlp による解決の可否に依る。仕様書はそのため
  # 二段の判定を定めており、ここにあるのはその一段目だけである。
  #
  # 二段目（yt-dlp）が入るまで、表示名は「YouTube」のままにする。
  # 仕様書 4 が挙げる「YouTube (yt-dlp解決)」を先に名乗ると、
  # 見ている人に、まだしていない検査をしたと伝えることになる。
  class Repository < Status::SourceRepository
    OEMBED_URL = "https://www.youtube.com/oembed"

    # endpoint を受け取るのは spec から差し替えるためである。
    # 表示に出す url は定数のままにする（仕様書 4）。
    def initialize(@video_id : String, @endpoint : String = OEMBED_URL)
    end

    def service_id : String
      "youtube"
    end

    def display_name : String
      "YouTube"
    end

    def display_url : String
      "https://www.youtube.com"
    end

    def source_kind : Status::SourceKind
      Status::SourceKind::Synthetic
    end

    # 作者自身のチャンネルの公開動画。上流の都合で消えないものを選ぶ（仕様書 3.3）。
    def watch_url : String
      "https://www.youtube.com/watch?v=#{@video_id}"
    end

    def oembed_url : String
      "#{@endpoint}?#{URI::Params.encode({"url" => watch_url, "format" => "json"})}"
    end

    def observe : Status::Observation
      started = Time.instant
      response = Upstream.get(oembed_url)
      latency = Time.instant - started

      # 届かなかったのか、断られたのか、返ってきたものが読めなかったのかで、
      # 次に見る先が変わる。言い分けて残す。
      unless response.status_code == 200
        return failure("oEmbed が応答しない（HTTP #{response.status_code}）")
      end
      return failure("oEmbed の応答が JSON でない") unless resolved?(response.body)

      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Success,
        checked_at: Time.utc,
        latency: latency,
      )
    rescue error
      failure("oEmbed に届かない（#{error.message || error.class.name}）")
    end

    # 動画が解決できたか。題が読めれば解決できている。
    private def resolved?(body : String) : Bool
      OEmbed.from_json(body)
      true
    rescue
      false
    end

    private def failure(reason : String) : Status::Observation
      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Failure,
        checked_at: Time.utc,
        note: reason,
      )
    end
  end
end
