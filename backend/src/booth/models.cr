require "html"

module Booth
  # お知らせページ（https://booth.pm/announcements）の HTML からの題名の抽出（仕様書 3.3）。
  #
  # BOOTH に公式のステータスページは無く、障害やメンテナンスの告知はこのページに
  # 事後掲載される。判定には使わず、表示の補助として note に載せるだけである。
  #
  # HTML の解析に shard は使わない。読みたいのは最新の告知の題名一つだけで、
  # それを囲む要素を文字列で探せば足りる。構造は 2026-09-05 に取った実物
  # （spec/booth/fixtures/announcements.html）で見た。
  #
  #   <a class="legacy-list-item nav" href="/announcements/981">
  #     ...<span class="notice badge announcement_type">重要</span>...
  #     <div class="u-mt-sp-200">題名</div>
  #     ...<div class="... date ...">2026年9月1日</div>...
  #   </a>
  #
  # 告知は新しいものから並び、一覧の一件目が最新である。
  module Announcements
    # 題名にこれを含む告知だけを note に載せる（仕様書 3.3）。
    KEYWORDS = ["障害", "メンテナンス"]

    # 一件の始まり。一覧の中でだけ現れ、ページの他の場所には無い。
    ITEM_MARKER = %(href="/announcements/)

    # 題名を囲む要素の開き。この class は題名にしか付いていない。
    TITLE_MARKER = %(class="u-mt-sp-200">)
    TITLE_END    = "</div>"

    # 最新の告知の題名。構造が変わって見つからなければ nil。
    #
    # 一件目の中に題名の要素が無いときも nil にする。二件目以降から拾うと、
    # 一件目だけ形が変わった場合に古い告知を最新として返してしまう。
    def self.latest_title(html : String) : String?
      item_start = html.index(ITEM_MARKER)
      return unless item_start

      title_start = html.index(TITLE_MARKER, item_start)
      return unless title_start

      next_item = html.index(ITEM_MARKER, item_start + ITEM_MARKER.size)
      return if next_item && title_start > next_item

      title_start += TITLE_MARKER.size
      title_end = html.index(TITLE_END, title_start)
      return unless title_end

      title = HTML.unescape(html[title_start...title_end]).strip
      title.empty? ? nil : title
    end

    # 表示に載せる題名。障害でもメンテナンスでもなければ空。
    #
    # 見るのは最新の一件だけである。一覧全体から探すと、決済事業者の
    # メンテナンスのような告知が、次の告知に押し出されるまで何週間も
    # note に残る。告知は事後掲載で復旧後も残る（仕様書 3.3）ので、
    # 表示に出す範囲は最新の一件に絞る。
    def self.notice(title : String) : String
      KEYWORDS.any? { |keyword| title.includes?(keyword) } ? title : ""
    end
  end
end
