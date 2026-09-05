require "../spec_helper"

private record Stub, status : HTTP::Status = HTTP::Status::OK, body : String = ""

# 実物と同じ構造で、一件目の題名だけを差し替えたお知らせページ。
private def announcements(title : String) : String
  <<-HTML
    <html><body><div class="list list--outline0">
      <a class="legacy-list-item nav" href="/announcements/1">
        <div class="u-mr-300"><span class="notice badge announcement_type">重要</span></div>
        <div class="u-mt-sp-200">#{title}</div>
      </a>
    </div></body></html>
    HTML
end

private def maintenance : Stub
  Stub.new(body: announcements("「Buyee」メンテナンスのお知らせ"))
end

# お知らせページへの要求を数えるための、経路ごとの応答と時計。
private class BoothSite
  getter announcement_requests = 0
  property now : Time::Instant = Time.instant
  property announcements : Stub
  property endpoint = ""

  def initialize(@top : Stub, @item : Stub, @announcements : Stub)
  end

  def handle(context : HTTP::Server::Context) : Nil
    path = context.request.path
    stub =
      if path.starts_with?("/announcements")
        @announcement_requests += 1
        @announcements
      elsif path.starts_with?("/items")
        @item
      else
        @top
      end

    context.response.status = stub.status
    context.response.print stub.body
  end
end

private def with_booth(
  top : Stub = Stub.new,
  item : Stub = Stub.new,
  announcements : Stub = Stub.new(body: announcements("キャンペーンのお知らせ")),
  &
)
  site = BoothSite.new(top, item, announcements)

  with_stub_server(->site.handle(HTTP::Server::Context)) do |endpoint|
    site.endpoint = endpoint
    source = Booth::Repository.new(
      "123456",
      top_url: endpoint,
      announcements_url: "#{endpoint}/announcements",
      clock: -> { site.now },
    )
    yield source, site
  end
end

describe Booth::Repository do
  it "合成監視である" do
    Booth::Repository.new("123456").source_kind.should eq Status::SourceKind::Synthetic
  end

  it "作者自身の商品ページを見に行く" do
    Booth::Repository.new("123456").item_url.should eq "https://booth.pm/ja/items/123456"
  end

  it "どちらも返れば届いたものとする" do
    with_booth do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.service_id.should eq "booth"
      observation.partial?.should be_false
      observation.note.should eq ""
    end
  end

  # 商品ページだけが落ちるのは、その商品が消えたときにも起きる。
  # 月次の点検で見分けられるよう、どちらが落ちたかを残す（仕様書 9）。
  it "商品ページだけが落ちていれば一段下げる" do
    with_booth(item: Stub.new(status: HTTP::Status::NOT_FOUND)) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_true
      observation.note.should eq "商品ページが応答しない"
    end
  end

  it "トップだけが落ちていれば一段下げる" do
    with_booth(top: Stub.new(status: HTTP::Status::BAD_GATEWAY)) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_true
      observation.note.should eq "トップが応答しない"
    end
  end

  it "両方落ちていれば届かなかったものとする" do
    top = Stub.new(status: HTTP::Status::BAD_GATEWAY)
    item = Stub.new(status: HTTP::Status::NOT_FOUND)

    with_booth(top: top, item: item) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      # 片方だけを出すと、もう片方が何で落ちたか分からない。
      observation.note.should contain("502")
      observation.note.should contain("404")
    end
  end

  it "誰も答えなくても例外を外に出さない" do
    source = Booth::Repository.new("123456", top_url: "http://127.0.0.1:#{unused_port}")

    observation = source.observe

    observation.outcome.should eq Status::Outcome::Failure
    observation.note.should_not eq ""
  end

  describe "お知らせ" do
    it "最新の告知がメンテナンスなら題名を note に載せる" do
      with_booth(announcements: maintenance) do |source|
        observation = source.observe

        observation.outcome.should eq Status::Outcome::Success
        observation.partial?.should be_false
        observation.note.should eq "「Buyee」メンテナンスのお知らせ"
      end
    end

    it "最新の告知が障害でもメンテナンスでもなければ note は空のまま" do
      with_booth do |source, site|
        source.observe.note.should eq ""
        site.announcement_requests.should eq 1
      end
    end

    it "片方が落ちていれば、その様子の後ろに題名を添える" do
      with_booth(item: Stub.new(status: HTTP::Status::NOT_FOUND), announcements: maintenance) do |source|
        observation = source.observe

        observation.partial?.should be_true
        observation.note.should eq "商品ページが応答しない / 「Buyee」メンテナンスのお知らせ"
      end
    end

    it "両方落ちていても題名を添える" do
      top = Stub.new(status: HTTP::Status::BAD_GATEWAY)
      item = Stub.new(status: HTTP::Status::BAD_GATEWAY)

      with_booth(top: top, item: item, announcements: maintenance) do |source|
        observation = source.observe

        observation.outcome.should eq Status::Outcome::Failure
        observation.note.should end_with(" / 「Buyee」メンテナンスのお知らせ")
      end
    end

    it "間隔の内では取り直さず、過ぎれば取り直す" do
      with_booth(announcements: maintenance) do |source, site|
        source.observe
        site.now += Booth::Repository::ANNOUNCEMENT_INTERVAL - 1.second
        source.observe
        site.announcement_requests.should eq 1

        site.now += 1.second
        source.observe
        site.announcement_requests.should eq 2
      end
    end

    it "取り直したら題名も入れ替わる" do
      with_booth(announcements: maintenance) do |source, site|
        source.observe.note.should eq "「Buyee」メンテナンスのお知らせ"

        site.announcements = Stub.new(body: announcements("キャンペーンのお知らせ"))
        site.now += Booth::Repository::ANNOUNCEMENT_INTERVAL
        source.observe.note.should eq ""
      end
    end

    # 告知は表示の補助である。取れなかったことで判定が動いてはならない（仕様書 3.3）。
    it "お知らせページが応答しなくても観測は成功のまま、前回の題名を残す" do
      with_booth(announcements: maintenance) do |source, site|
        source.observe

        site.announcements = Stub.new(status: HTTP::Status::SERVICE_UNAVAILABLE)
        site.now += Booth::Repository::ANNOUNCEMENT_INTERVAL

        Log.capture("booth") do |logs|
          observation = source.observe

          observation.outcome.should eq Status::Outcome::Success
          observation.partial?.should be_false
          observation.note.should eq "「Buyee」メンテナンスのお知らせ"
          logs.check(:warn, /503/)
        end
      end
    end

    it "お知らせページに届かなくても観測は成功のまま" do
      with_booth do |_, site|
        source = Booth::Repository.new(
          "123456",
          top_url: site.endpoint,
          announcements_url: "http://127.0.0.1:#{unused_port}",
        )

        Log.capture("booth") do |logs|
          observation = source.observe

          observation.outcome.should eq Status::Outcome::Success
          observation.note.should eq ""
          logs.check(:warn, /取れなかった/)
        end
      end
    end

    # 間隔は取りに行った時刻から数える。失敗のたびに取り直すと、BOOTH が
    # 落ちているあいだ、いちばん叩いてはいけないときに毎分叩くことになる。
    it "取れなくても間隔の内では取り直さない" do
      with_booth(announcements: Stub.new(status: HTTP::Status::SERVICE_UNAVAILABLE)) do |source, site|
        Log.capture("booth", :warn) do
          source.observe
          site.now += Booth::Repository::ANNOUNCEMENT_INTERVAL - 1.second
          source.observe
        end

        site.announcement_requests.should eq 1
      end
    end

    it "題名が見つからなければ空にしてログに残す" do
      with_booth(announcements: maintenance) do |source, site|
        source.observe.note.should eq "「Buyee」メンテナンスのお知らせ"

        site.announcements = Stub.new(body: "<html><body>作り直されたページ</body></html>")
        site.now += Booth::Repository::ANNOUNCEMENT_INTERVAL

        Log.capture("booth") do |logs|
          source.observe.note.should eq ""
          logs.check(:warn, /見つからない/)
        end
      end
    end

    it "お知らせページの所要はレイテンシに入れない" do
      slow = Stub.new(body: announcements("キャンペーンのお知らせ"))
      site = BoothSite.new(Stub.new, Stub.new, slow)
      handler = ->(context : HTTP::Server::Context) do
        sleep 200.milliseconds if context.request.path.starts_with?("/announcements")
        site.handle(context)
      end

      with_stub_server(handler) do |endpoint|
        source = Booth::Repository.new("123456", top_url: endpoint, announcements_url: "#{endpoint}/announcements")

        observation = source.observe

        latency = observation.latency
        latency.should_not be_nil
        latency.should be < 200.milliseconds if latency
      end
    end
  end
end
