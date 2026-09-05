require "../spec_helper"

# 2026-09-05 に取ったお知らせページの実物。一件目はキャンペーンの告知である。
private def announcements_html : String
  File.read(File.join(__DIR__, "fixtures", "announcements.html"))
end

# 実物と同じ構造で、題名だけを差し替えた一覧。
private def listing(*titles : String) : String
  items = titles.map do |title|
    <<-HTML
      <a class="legacy-list-item nav" href="/announcements/1">
        <div class="legacy-list-item__center u-py-400"><div class="flex flex-[1]"><div class="flex flex-[1] mobile:block">
          <div class="u-mr-300"><span class="notice badge announcement_type">重要</span></div>
          <div class="u-mt-sp-200">#{title}</div>
        </div><div class="l-annoucements-date"><div class="self-start u-mt-200 u-tpg-caption1 date text-text-default">2026年9月1日</div></div></div></div>
      </a>
      HTML
  end

  %(<html><body><div class="list list--outline0">#{items.join}</div></body></html>)
end

describe Booth::Announcements do
  describe ".latest_title" do
    it "実物の一覧から一件目の題名を取り出す" do
      title = Booth::Announcements.latest_title(announcements_html)

      title.should eq "最大5%必ずもらえる＆はじめて利用でさらに1,000円相当が当たる！pixivcoban売上チャージWチャンスキャンペーン"
    end

    it "二件目以降ではなく一件目を返す" do
      html = listing("新しい告知", "古い障害のお知らせ")

      Booth::Announcements.latest_title(html).should eq "新しい告知"
    end

    it "文字参照と前後の空白をほどく" do
      html = listing("  A &amp; B\n")

      Booth::Announcements.latest_title(html).should eq "A & B"
    end

    it "一覧が無ければ見つからないものとする" do
      Booth::Announcements.latest_title("<html><body>メンテナンス中</body></html>").should be_nil
    end

    it "一件目に題名の要素が無ければ、二件目から拾わずに見つからないものとする" do
      # 一件目だけ形が変わった場合に、二件目を最新として返さないためである。
      broken = %(<a class="legacy-list-item nav" href="/announcements/2"><div>題名の無い一件目</div></a>)
      html = listing("二件目のメンテナンスのお知らせ").sub(%(<a class="legacy-list-item nav"), broken + %(<a class="legacy-list-item nav"))

      Booth::Announcements.latest_title(html).should be_nil
    end

    it "一覧より前にある同じ class の要素を題名と取り違えない" do
      # u-mt-sp-200 は余白の utility class で、題名のためだけの名前ではない。
      html = listing("メンテナンスのお知らせ").sub(%(<div class="list), %(<div class="u-mt-sp-200">ヘッダの障害情報</div><div class="list))

      Booth::Announcements.latest_title(html).should eq "メンテナンスのお知らせ"
    end

    it "題名が空なら見つからないものとする" do
      Booth::Announcements.latest_title(listing("   ")).should be_nil
    end
  end

  describe ".notice" do
    it "障害を含む題名を載せる" do
      Booth::Announcements.notice("【障害】決済がご利用いただけない不具合について").should eq "【障害】決済がご利用いただけない不具合について"
    end

    it "メンテナンスを含む題名を載せる" do
      Booth::Announcements.notice("「Buyee」メンテナンスのお知らせ").should eq "「Buyee」メンテナンスのお知らせ"
    end

    it "どちらも含まない題名は載せない" do
      Booth::Announcements.notice("大雨の影響による荷物のお届け遅延について").should eq ""
    end

    it "実物の一件目はキャンペーンなので載せない" do
      title = Booth::Announcements.latest_title(announcements_html)

      title.should_not be_nil
      Booth::Announcements.notice(title.to_s).should eq ""
    end
  end
end
