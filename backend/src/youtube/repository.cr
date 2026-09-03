require "uri"
require "../status/models"
require "../status/repository"
require "../upstream"
require "../vrchat_api/repository"
require "../ytdlp/repository"
require "./models"

module Youtube
  # YouTube の合成監視（仕様書 3.3）。
  #
  # 知りたいのは「ワールドの動画プレイヤーで再生できるか」で、それは
  # サイトの稼働よりも yt-dlp による解決の可否に依る。
  # そのため仕様書 3.3 は二段の判定を定めている。
  #
  # 一段目は oEmbed で、サイトが動いていることを見る。
  # 二段目は yt-dlp で、その動画を実際に解決できることを見る。
  # 一段目が通らなければ二段目は試さない。サイトが落ちているなら
  # 解決できないのは当たり前で、確かめても分かることが増えない。
  class Repository < Status::SourceRepository
    OEMBED_URL = "https://www.youtube.com/oembed"

    # 同梱版と食い違っているときに note へ出す文言（仕様書 7.3）。
    MISMATCH = "VRChat 同梱版と不一致"

    # endpoint を受け取るのは spec から差し替えるためである。
    # 表示に出す url は定数のままにする（仕様書 4）。
    #
    # bundled と layer_version は同梱版の照合に使う（仕様書 7.3）。
    # bundled が nil なら照合しない。
    def initialize(
      @video_id : String,
      @ytdlp : Ytdlp::Repository = Ytdlp::Repository.new,
      @endpoint : String = OEMBED_URL,
      @bundled : VrchatApi::Repository? = nil,
      @layer_version : String = "",
    )
    end

    def service_id : String
      "youtube"
    end

    # 解決の可否で判じていることを名前で示す（仕様書 4）。
    def display_name : String
      "YouTube (yt-dlp解決)"
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

      # 例外を拾う範囲は、この取得だけにする。
      # 広げると、二段目で起きたことまで「oEmbed に届かない」と言い出す。
      response = begin
        Upstream.get(oembed_url)
      rescue error
        return failure("oEmbed に届かない（#{error.message || error.class.name}）")
      end

      # レイテンシは oEmbed の分だけを測る。
      # yt-dlp のほうには自身の展開にかかる時間が含まれ、それは YouTube の
      # 速さではない。合わせて測ると、しきい値（仕様書 3.3）を毎回超える。
      latency = Time.instant - started

      # 届かなかったのか、断られたのか、返ってきたものが読めなかったのかで、
      # 次に見る先が変わる。言い分けて残す。
      unless response.status_code == 200
        return failure("oEmbed が応答しない（HTTP #{response.status_code}）")
      end
      return failure("oEmbed の応答が JSON でない") unless resolved?(response.body)

      judge(@ytdlp.probe(@video_id), latency)
    end

    # 二段目の結果を観測に写す（仕様書 3.3、7.2）。
    private def judge(result : Ytdlp::Result, latency : Time::Span) : Status::Observation
      case result.outcome
      in Ytdlp::Outcome::Resolved
        observation(Status::Outcome::Success, latency, note: mismatch_note)
      in Ytdlp::Outcome::Unresolved
        # サイトは動いているのに解決できない。
        # 再生はできないが YouTube が落ちたわけではないので、
        # 失敗とは数えず一段の低下にとどめる。
        #
        # 解決できない理由のほうが、版の食い違いより先に読まれるべきものである。
        # yt-dlp の note が空のときだけ、食い違いを出す。
        observation(Status::Outcome::Success, latency, note: result.note.presence || mismatch_note, partial: true)
      in Ytdlp::Outcome::Unavailable
        # 検査そのものが成り立っていない。
        # 解決できなかったのと同じ顔をさせると、Layer が載っていない状態が
        # 何日続いても「少し調子が悪い YouTube」としか出ない。
        observation(Status::Outcome::Indeterminate, latency, note: result.note)
      in Ytdlp::Outcome::Indeterminate
        # AWS の IP からの取得は bot 検知を受けやすく、この誤判定は
        # 構造的に避けられない（仕様書 7.4）。赤くせず判定不能へ逃がす。
        observation(Status::Outcome::Indeterminate, latency, note: result.note)
      end
    end

    private def observation(
      outcome : Status::Outcome,
      latency : Time::Span,
      note : String = "",
      partial : Bool = false,
    ) : Status::Observation
      Status::Observation.new(
        service_id: service_id,
        outcome: outcome,
        checked_at: Time.utc,
        latency: latency,
        note: note,
        partial: partial,
      )
    end

    # 同梱版と Layer の版が食い違っていれば、その旨（仕様書 7.3）。
    #
    # /config が取れなかったときは何も出さない。
    # 照合できなかったことは、YouTube の状態ではない。
    private def mismatch_note : String
      bundled = @bundled.try(&.version)
      return "" if bundled.nil? || bundled == @layer_version

      "#{MISMATCH}（同梱 #{bundled}）"
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
