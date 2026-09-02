require "../status/models"
require "../status/repository"
require "../upstream"

# BOOTH の合成監視（仕様書 3.3）。
#
# 公式のステータスページが無く、障害の告知はお知らせページに事後掲載される。
# そのため、トップと作者自身の商品ページが返るかで状態を推し量る。
#
# 購入後のダウンロード経路は監視しない。ログインが要るためである（仕様書 3.3）。
#
# models.cr を持たないのは、読む JSON がまだ無いからである。
# お知らせの題名を note に載せる仕組み（仕様書 3.3）はここに入っていない。
# 抽出は HTML の構造に依存し、その構造をまだ実物で見ていない（仕様書 12）。
module Booth
  class Repository < Status::SourceRepository
    TOP_URL = "https://booth.pm/ja"

    # top_url を受け取るのは spec から差し替えるためである。
    # 表示に出す url は定数のままにする（仕様書 4）。
    def initialize(@item_id : String, @top_url : String = TOP_URL)
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
      started = Time.instant
      top, item = Upstream.get_all([@top_url, item_url])
      latency = Time.instant - started

      top_ok = Upstream.ok?(top)
      item_ok = Upstream.ok?(item)

      # 両方落ちて初めて届かなかったとみなす（仕様書 3.3）。
      unless top_ok || item_ok
        return failure("BOOTH に届かない（#{Upstream.reason(top)}）")
      end

      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Success,
        checked_at: Time.utc,
        latency: latency,
        note: partial_note(top_ok, item_ok),
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
