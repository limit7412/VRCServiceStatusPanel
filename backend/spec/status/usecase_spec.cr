require "../spec_helper"

private def history_of(*outcomes : Status::Outcome) : Status::History
  outcomes.reduce(Status::History.new) { |history, outcome| history.push(outcome) }
end

# 決めた結果だけを返す取得元。判定の規則そのものを試すために使う。
# 遅らせるのは、結果の届く順が配信 JSON の並びを動かさないことを見るためである。
private class FakeSource < Status::SourceRepository
  getter service_id : String
  getter display_name : String
  getter display_url : String
  getter source_kind : Status::SourceKind

  def initialize(
    @service_id : String,
    @source_kind : Status::SourceKind = Status::SourceKind::Official,
    @observation : Status::Observation? = nil,
    @error : Exception? = nil,
    @delay : Time::Span? = nil,
    @display_name : String = "表示名",
    @display_url : String = "https://example.test",
  )
  end

  def observe : Status::Observation
    if delay = @delay
      sleep delay
    end

    if error = @error
      raise error
    end

    @observation || raise "観測を渡していない"
  end
end

# 書いたものと、その順番を覚えておく書き出し先。
private class FakeFeeds < Status::FeedRepository
  getter states = [] of Status::State
  getter feeds = [] of Status::Feed
  getter calls = [] of String

  def initialize(@state : Status::State? = nil)
  end

  def load_state : Status::State?
    @state
  end

  def save_state(state : Status::State) : Nil
    @calls << "state"
    @states << state
  end

  def save_feed(feed : Status::Feed) : Nil
    @calls << "feed"
    @feeds << feed
  end
end

private NOW = Time.unix(1_756_123_200)

private def success(id : String, level : Status::Level, note : String = "", latency : Time::Span? = nil)
  Status::Observation.new(
    service_id: id,
    outcome: Status::Outcome::Success,
    checked_at: NOW,
    latency: latency,
    note: note,
    level: level,
  )
end

private def failure(id : String, note : String = "HTTP 500")
  Status::Observation.new(
    service_id: id,
    outcome: Status::Outcome::Failure,
    checked_at: NOW,
    note: note,
  )
end

private def previous_status(id : String, level : Status::Level, note : String, checked_at : Time)
  Status::ServiceStatus.new(
    id: id,
    name: "表示名",
    level: level,
    source: Status::SourceKind::Official,
    url: "https://example.test",
    checked_at: checked_at,
    note: note,
  )
end

private def refresh(sources : Array(Status::SourceRepository), feeds : FakeFeeds) : Status::Feed
  Status::Usecase.new(sources, feeds).refresh(NOW)
end

describe Status::Usecase do
  describe "#refresh" do
    it "公式ステータスページの応答をそのまま写す" do
      source = FakeSource.new(
        service_id: "vrchat",
        observation: success("vrchat", Status::Level::Degraded, "Websocket: Partial Outage"),
      )
      feeds = FakeFeeds.new

      feed = refresh([source] of Status::SourceRepository, feeds)

      service = feed.services.first
      service.id.should eq "vrchat"
      service.level.should eq Status::Level::Degraded.value
      service.note.should eq "Websocket: Partial Outage"
      service.checked_unix.should eq NOW.to_unix
      feed.stale?.should be_false
    end

    # 取得の失敗はこちら側の事情であって、上流が落ちたことではない（仕様書 5.3）。
    it "公式ステータスページを取れなければ前回値を引き継ぐ" do
      checked_at = NOW - 1.minute
      state = Status::State.new(
        services: {
          "vrchat" => previous_status("vrchat", Status::Level::Degraded, "前回の note", checked_at),
        }
      )
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::Degraded.value
      service.note.should eq "前回の note"
      service.checked_unix.should eq checked_at.to_unix
    end

    it "五分取れないままなら判定不能にする" do
      checked_at = NOW - 5.minutes
      state = Status::State.new(
        services: {
          "vrchat" => previous_status("vrchat", Status::Level::Operational, "前回の note", checked_at),
        }
      )
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::Unknown.value
      # 判定できないと言いながら中身を説明し続けることになるので、note も落とす。
      service.note.should eq ""
      # 最後に取れた時刻だけは動かさない。
      service.checked_unix.should eq checked_at.to_unix
    end

    it "境界の手前では前回値を保つ" do
      checked_at = NOW - 5.minutes + 1.second
      state = Status::State.new(
        services: {
          "vrchat" => previous_status("vrchat", Status::Level::Operational, "", checked_at),
        }
      )
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      feed.services.first.level.should eq Status::Level::Operational.value
    end

    it "一度も取れていなければ判定不能から始める" do
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new)

      service = feed.services.first
      service.level.should eq Status::Level::Unknown.value
      # 取得できた時刻が無いことを 0 で表す。
      service.checked_unix.should eq 0
      # 失敗の理由はログに残すもので、表示には出さない。
      service.note.should eq ""
    end

    it "合成監視は履歴から決める" do
      state = Status::State.new(
        histories: {"steam" => history_of(Status::Outcome::Failure)}
      )
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: failure("steam"),
      )
      feeds = FakeFeeds.new(state)

      feed = refresh([source] of Status::SourceRepository, feeds)

      # 前回と今回で二回失敗しているので全断とみなす（仕様書 3.3）。
      feed.services.first.level.should eq Status::Level::MajorOutage.value
      feeds.states.first.history_of("steam").outcomes.size.should eq 2
    end

    # 届かなかったこと自体が判定の材料なので、前回値へは戻さない。
    it "合成監視は失敗しても最後に見た時刻を進める" do
      state = Status::State.new(
        services: {
          "steam" => previous_status("steam", Status::Level::Operational, "", NOW - 1.hour),
        }
      )
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: failure("steam"),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new(state))

      service = feed.services.first
      service.level.should eq Status::Level::Degraded.value
      service.checked_unix.should eq NOW.to_unix
    end

    it "合成監視はレイテンシの超過を一段の低下として扱う" do
      source = FakeSource.new(
        service_id: "steam",
        source_kind: Status::SourceKind::Synthetic,
        observation: success("steam", Status::Level::Operational, latency: 3.seconds),
      )

      feed = refresh([source] of Status::SourceRepository, FakeFeeds.new)

      feed.services.first.level.should eq Status::Level::Degraded.value
    end

    # observe は例外を出さない契約だが（仕様書 11.4）、破られても他は止めない。
    it "一つの取得元が例外を出しても他のサービスを更新する" do
      broken = FakeSource.new(service_id: "vrchat", error: Exception.new("壊れている"))
      working = FakeSource.new(
        service_id: "discord",
        observation: success("discord", Status::Level::Operational),
      )

      feed = refresh([broken, working] of Status::SourceRepository, FakeFeeds.new)

      feed.services.map(&.id).should eq ["vrchat", "discord"]
      feed.services.first.level.should eq Status::Level::Unknown.value
      feed.services.last.level.should eq Status::Level::Operational.value
    end

    it "ひとつも取れなければ stale にする" do
      source = FakeSource.new(service_id: "vrchat", observation: failure("vrchat"))

      refresh([source] of Status::SourceRepository, FakeFeeds.new).stale?.should be_true
    end

    it "ひとつでも取れれば stale にしない" do
      sources = [
        FakeSource.new(service_id: "vrchat", observation: failure("vrchat")),
        FakeSource.new(service_id: "discord", observation: success("discord", Status::Level::Operational)),
      ] of Status::SourceRepository

      refresh(sources, FakeFeeds.new).stale?.should be_false
    end

    # 結果は先に終わったものから届く。そのまま並べると、実行のたびに
    # パネルの行が入れ替わることになる。
    it "渡された順に並べる" do
      sources = [
        FakeSource.new(
          service_id: "slow",
          observation: success("slow", Status::Level::Operational),
          delay: 20.milliseconds,
        ),
        FakeSource.new(
          service_id: "fast",
          observation: success("fast", Status::Level::Operational),
        ),
      ] of Status::SourceRepository

      refresh(sources, FakeFeeds.new).services.map(&.id).should eq ["slow", "fast"]
    end

    it "取得元を並列に呼ぶ" do
      sources = [
        FakeSource.new(
          service_id: "a",
          observation: success("a", Status::Level::Operational),
          delay: 30.milliseconds,
        ),
        FakeSource.new(
          service_id: "b",
          observation: success("b", Status::Level::Operational),
          delay: 30.milliseconds,
        ),
      ] of Status::SourceRepository

      started = Time.instant
      refresh(sources, FakeFeeds.new)

      # 順に呼べば 60 ミリ秒かかる。並べて呼べば 30 ミリ秒ほどで終わる。
      (Time.instant - started).should be < 55.milliseconds
    end

    # 配信を先にすると、その間に落ちたとき、配っている内容の根拠が内部に残らない。
    it "状態を書いてから配信する" do
      source = FakeSource.new(
        service_id: "vrchat",
        observation: success("vrchat", Status::Level::Operational),
      )
      feeds = FakeFeeds.new

      refresh([source] of Status::SourceRepository, feeds)

      feeds.calls.should eq ["state", "feed"]
    end

    it "次の実行へ引き継ぐ状態を書く" do
      source = FakeSource.new(
        service_id: "vrchat",
        observation: success("vrchat", Status::Level::Degraded, "note"),
      )
      feeds = FakeFeeds.new

      refresh([source] of Status::SourceRepository, feeds)

      state = feeds.states.first
      state.version.should eq Status::State::SCHEMA_VERSION
      state.service_of("vrchat").try(&.note).should eq "note"
      state.history_of("vrchat").outcomes.should eq [Status::Outcome::Success]
    end
  end

  describe ".level_for_synthetic" do
    it "is operational when every recent check succeeded" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Success,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Operational
    end

    it "is degraded after a single failure" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Failure,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Degraded
    end

    it "is degraded when the latency threshold was exceeded" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Success,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history, latency_exceeded: true)
        .should eq Status::Level::Degraded
    end

    it "is a major outage from the second failure" do
      history = history_of(
        Status::Outcome::Failure,
        Status::Outcome::Success,
        Status::Outcome::Failure,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::MajorOutage
    end

    it "is unknown when the latest response looked like bot detection" do
      history = history_of(
        Status::Outcome::Failure,
        Status::Outcome::Failure,
        Status::Outcome::Indeterminate,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Unknown
    end

    it "judges from the current run alone when no history was restored" do
      Status::Usecase.level_for_synthetic(Status::History.new)
        .should eq Status::Level::Operational

      Status::Usecase.level_for_synthetic(history_of(Status::Outcome::Failure))
        .should eq Status::Level::Degraded
    end
  end
end
