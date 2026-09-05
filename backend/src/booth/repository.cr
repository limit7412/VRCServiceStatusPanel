require "../status/models"
require "../status/repository"
require "../upstream"
require "./models"

# BOOTH の合成監視（仕様書 3.3）。
#
# 公式のステータスページが無く、障害の告知はお知らせページに事後掲載される。
# そのため、トップと作者自身の商品ページが返るかで状態を推し量る。
#
# 購入後のダウンロード経路は監視しない。ログインが要るためである（仕様書 3.3）。
#
# お知らせページは 10 分に一度だけ取り、最新の告知が障害かメンテナンスなら
# その題名を note に載せる。level には使わない（仕様書 3.3）。
module Booth
  class Repository < Status::SourceRepository
    Log = ::Log.for("booth")

    TOP_URL           = "https://booth.pm/ja"
    ANNOUNCEMENTS_URL = "https://booth.pm/announcements"

    # お知らせページを取る間隔（仕様書 3.3）。
    # 告知は事後掲載なので、毎分見ても早く分かるわけではない。
    ANNOUNCEMENT_INTERVAL = 10.minutes

    # お知らせページを最後に取りに行った時刻と、そのとき得た題名。
    #
    # インスタンスはコールドスタート時に一度だけ作るため、ウォームスタートの
    # あいだ生き続ける。State には入れない（仕様書 3.3）。コールドスタートの
    # たびに一度余分に取ることになるが、それは日に数回である。
    @announced_at : Time::Instant?
    @notice = ""

    # top_url と announcements_url を受け取るのは spec から差し替えるためである。
    # 表示に出す url は定数のままにする（仕様書 4）。
    #
    # clock を受け取るのは、10 分の境界を spec から動かすためである。
    # observe は引数を取らない契約（仕様書 11.4）なので、時刻はここから注す。
    def initialize(
      @item_id : String,
      @top_url : String = TOP_URL,
      @announcements_url : String = ANNOUNCEMENTS_URL,
      @announcement_interval : Time::Span = ANNOUNCEMENT_INTERVAL,
      @clock : -> Time::Instant = -> { Time.instant },
    )
    end

    def service_id : String
      "booth"
    end

    def display_name : String
      "BOOTH"
    end

    def display_url : String
      TOP_URL
    end

    def source_kind : Status::SourceKind
      Status::SourceKind::Synthetic
    end

    # 作者自身の公開商品。上流の都合で消えないものを選ぶ（仕様書 3.3）。
    def item_url : String
      "#{@top_url}/items/#{@item_id}"
    end

    def observe : Status::Observation
      # お知らせは判定の二経路と並べて取る。後に回すと、お知らせページだけが
      # 遅い日に、その分だけ観測が長引く。レイテンシに混ぜないのは、
      # 判定に使うのがトップと商品ページの応答だけだからである（仕様書 3.3）。
      notice = Channel(String).new(1)
      spawn { notice.send(current_notice) }

      started = Time.instant
      top, item = Upstream.get_all([@top_url, item_url])
      latency = Time.instant - started

      top_ok = Upstream.ok?(top)
      item_ok = Upstream.ok?(item)
      announcement = notice.receive

      # 両方落ちて初めて届かなかったとみなす（仕様書 3.3）。
      # 二つとも理由を残す。片方だけを出すと、もう片方が何で落ちたか分からない。
      unless top_ok || item_ok
        reason = "BOOTH に届かない（#{Upstream.reason(top)} / #{Upstream.reason(item)}）"
        return failure(with_notice(reason, announcement))
      end

      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Success,
        checked_at: Time.utc,
        latency: latency,
        note: with_notice(partial_note(top_ok, item_ok), announcement),
        partial: !(top_ok && item_ok),
      )
    rescue error
      failure(error.message || error.class.name)
    end

    # 片方だけが落ちているときに、どちらかを出す。
    # 商品ページだけが落ちる場合は、その商品が消えた可能性もある。
    # 月次の点検でそこを見る（仕様書 9）ため、どちらが落ちたかを残す。
    private def partial_note(top_ok : Bool, item_ok : Bool) : String
      return "商品ページが応答しない" unless item_ok
      return "トップが応答しない" unless top_ok

      ""
    end

    # 経路の様子の後ろに告知の題名を添える。
    # 経路の様子が先なのは、それが level の理由だからである。告知は補助に過ぎない。
    private def with_notice(note : String, announcement : String) : String
      return note if announcement.empty?
      return announcement if note.empty?

      "#{note} / #{announcement}"
    end

    # いま note に載せる告知。間隔が過ぎていればお知らせページを取り直す。
    #
    # 間隔は取りに行った時刻から数え、取れたかどうかで変えない。
    # 失敗のたびに取り直すと、BOOTH が落ちているあいだ、いちばん叩いては
    # いけないときに毎分叩くことになる。
    #
    # 例外は外に出さない。告知は表示の補助で、取れなくても判定は成り立つ。
    private def current_notice : String
      now = @clock.call
      last = @announced_at

      if last.nil? || now - last >= @announcement_interval
        @announced_at = now
        refresh_notice
      end

      @notice
    rescue error
      Log.warn(exception: error) { "お知らせページを取れなかった" }
      @notice
    end

    # 取れなかったときは前回の題名を残す。一時的な失敗で表示が消えたり戻ったり
    # しないためである。題名が見つからないときだけ空にする。構造が変わったのなら
    # 前回の題名も当てにならず、古い告知を出し続けるほうが害が大きい（#48）。
    private def refresh_notice : Nil
      response = Upstream.get(@announcements_url)

      unless response.status_code == 200
        Log.warn { "お知らせページが応答しない（HTTP #{response.status_code}）" }
        return
      end

      title = Announcements.latest_title(response.body)

      if title.nil?
        Log.warn { "お知らせページに題名が見つからない。構造が変わった可能性がある" }
        @notice = ""
        return
      end

      @notice = Announcements.notice(title)
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
