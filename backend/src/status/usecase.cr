require "log"
require "./models"
require "./repository"

module Status
  class Usecase
    Log = ::Log.for("status")

    # 合成監視のレイテンシしきい値と接続タイムアウト（仕様書 3.3）。
    LATENCY_THRESHOLD = 3.seconds
    CONNECT_TIMEOUT   = 5.seconds

    # 取得できない状態がこれだけ続いたら Unknown にする（仕様書 5.3）。
    UNKNOWN_AFTER = 5.minutes

    # 取得元の並びが、そのまま配信 JSON の services の並びになる（仕様書 4）。
    def initialize(@sources : Array(SourceRepository), @feeds : FeedRepository)
    end

    # 一回の実行（仕様書 5.2、11.5）。
    #
    # now を引数で受けるのは、前回値をいつまで引き継ぐかの境界を spec から
    # 確かめるためである。呼び出し側は省いて使う。
    def refresh(now : Time? = nil) : Feed
      started = Time.instant
      previous = @feeds.load_state || State.new
      loaded = Time.instant
      observations, elapsed = observe_all
      observed = Time.instant

      # 時刻は観測を終えてから採る。
      #
      # 先に採ると、上流を待った数秒のぶんだけ古い値が配信の生成時刻になり、
      # 成功した観測の checked_unix より generated_unix が前に出る。
      # 前回値をいつまで引き継ぐかの判定も、同じだけ甘くなる。
      generated_at = now || Time.utc

      report_failures(observations)

      histories = {} of String => History
      services = [] of ServiceStatus

      @sources.each_with_index do |source, index|
        observation = observations[index]

        history = previous.history_of(source.service_id).push(observation.outcome)
        histories[source.service_id] = history

        services << status_for(source, observation, history, previous, generated_at)
      end

      feed = Feed.new(
        generated_at: generated_at,
        stale: observations.none?(&.success?),
        services: services,
      )
      state = State.new(
        histories: histories,
        services: services.to_h { |service| {service.id, service} },
      )

      # 状態を先に書く（仕様書 11.5）。
      # 配信を先にすると、その間に落ちたとき、配っている内容の根拠が内部に残らない。
      # 書き出しが落ちても内訳は残す。
      # R2 が遅延源のときほど書き出しで落ちやすく、そのときに限って
      # save の値が記録から抜けるのでは、この行を置いた意味が無い。
      begin
        @feeds.save_state(state)
        @feeds.save_feed(feed)
      ensure
        report_timing(observations, elapsed, load: loaded - started, observe: observed - loaded, save: Time.instant - observed)
      end

      feed
    end

    # 一回の実行の内訳を一行に残す。
    #
    # Lambda の REPORT 行には実行全体の時間しか出ない。dev で毎回 4.5 秒かかって
    # いたとき、それが合成監視なのか Statuspage なのか R2 なのかを、その行からは
    # 言い分けられなかった。取得は並列なので、上流ごとの所要時間が無いと
    # いちばん遅い一つが分からない。
    #
    # 上流ごとの値は Observation#latency ではなく、observe を呼んでから返るまでを
    # こちらで測ったものである。latency は取れたときにしか入らないので、
    # タイムアウトで落ちた一つ、つまりいちばん知りたいものが抜ける。
    private def report_timing(
      observations : Array(Observation),
      elapsed : Array(Time::Span),
      load : Time::Span,
      observe : Time::Span,
      save : Time::Span,
    ) : Nil
      Log.info do
        per_source = observations.map_with_index do |observation, index|
          "#{observation.service_id}=#{format_span(elapsed[index])}"
        end
        "所要 load=#{format_span(load)} observe=#{format_span(observe)} save=#{format_span(save)} #{per_source.join(" ")}"
      end
    end

    private def format_span(span : Time::Span) : String
      "#{span.total_milliseconds.round.to_i}ms"
    end

    # 取れなかった取得元を一行にまとめて残す。
    #
    # official の失敗は前回値へ戻るだけで、表示にも stale にも出ない
    # （仕様書 5.3、4）。他が取れていれば stale も偽のままである。
    # ここで残さなければ、一つの取得元が何日落ちていても記録のどこにも現れない。
    #
    # 一件を一行に収めるのは CloudWatch が改行で記録を割るためで、
    # runtime/lambda.cr の整形と同じ都合である。
    private def report_failures(observations : Array(Observation)) : Nil
      failed = observations.reject(&.success?)
      return if failed.empty?

      Log.warn do
        details = failed.map { |observation| "#{observation.service_id}=#{observation.note}" }
        "取れなかった #{details.join(" ")}"
      end
    end

    # 取得元をファイバーで並べて呼び、全部の結果を待ち合わせる（仕様書 5.2）。
    #
    # 全体のタイムアウトは持たない。HTTP は Upstream の 5 秒で個別に切れ、
    # 全部が切れても R2 の読み書きと合わせて 7 秒ほどである。Lambda の 15 秒はそれより長い。
    #
    # 結果は渡された順に並べ直す。Channel から届く順は先に終わったものからで、
    # そのまま並べると配信 JSON の services の並びが実行ごとに変わってしまう。
    #
    # 取得元ごとの所要時間も一緒に返す。成否によらず observe の前後で測る。
    private def observe_all : {Array(Observation), Array(Time::Span)}
      channel = Channel({Int32, Observation, Time::Span}).new(@sources.size)

      @sources.each_with_index do |source, index|
        spawn do
          started = Time.instant
          observation = observe_safely(source)
          channel.send({index, observation, Time.instant - started})
        end
      end

      slots = Array(Observation?).new(@sources.size, nil)
      elapsed = Array(Time::Span).new(@sources.size, Time::Span.zero)
      @sources.size.times do
        index, observation, span = channel.receive
        slots[index] = observation
        elapsed[index] = span
      end

      observations = @sources.map_with_index do |source, index|
        slots[index] || failed(source, "観測が結果を返さなかった")
      end
      {observations, elapsed}
    end

    # observe は例外を外に出さない契約である（仕様書 11.4）。
    # 破られても、そこで止めずに失敗として扱う。一つの取得元の例外で
    # 実行全体が止まると、他のサービスまで更新が止まる。
    private def observe_safely(source : SourceRepository) : Observation
      source.observe
    rescue error
      Log.error(exception: error) { "観測が例外を出した service_id=#{source.service_id}" }
      failed(source, error.message || error.class.name)
    end

    private def failed(source : SourceRepository, reason : String) : Observation
      Observation.new(
        service_id: source.service_id,
        outcome: Outcome::Failure,
        checked_at: Time.utc,
        note: reason,
      )
    end

    private def status_for(
      source : SourceRepository,
      observation : Observation,
      history : History,
      previous : State,
      now : Time,
    ) : ServiceStatus
      case source.source_kind
      in SourceKind::Official
        official_status(source, observation, previous, now)
      in SourceKind::Synthetic
        synthetic_status(source, observation, history)
      end
    end

    # 公式ステータスページは応答をそのまま写す（仕様書 11.5）。
    #
    # 取れなかったときは前回の level と note を引き継ぎ、checked_unix も
    # 動かさない（仕様書 5.3）。取得の失敗はこちら側の事情であって、
    # 上流のサービスが落ちたことを意味しないためである。
    private def official_status(
      source : SourceRepository,
      observation : Observation,
      previous : State,
      now : Time,
    ) : ServiceStatus
      if observation.success?
        # 成功したのに level が無いのは、アダプタが約束を破ったときだけである。
        return build(
          source,
          level: observation.level || Level::Unknown,
          note: observation.note,
          checked_at: observation.checked_at,
          components: observation.components,
        )
      end

      last = previous.service_of(source.service_id)

      # 一度も取れていない。取得できた時刻が無いので 0 を置く。
      # ワールド側は checked_unix を表示に使わないため（仕様書 8.2）、
      # ここに何を置いても表示は壊れない。
      return build(source, level: Level::Unknown, note: "", checked_at: Time.unix(0)) if last.nil?

      checked_at = Time.unix(last.checked_unix)

      # 引き継げる前回値はあるが、古すぎて今を語れない（仕様書 5.3）。
      #
      # note と components も落とす。level だけを判定不能にして説明を残すと、
      # 「判定できない」と言いながら「Websocket が部分障害」と続けることになり、
      # パネルの一行が自分と食い違う。
      if now - checked_at >= UNKNOWN_AFTER
        return build(source, level: Level::Unknown, note: "", checked_at: checked_at)
      end

      build(
        source,
        level: Level.from_value?(last.level) || Level::Unknown,
        note: last.note,
        checked_at: checked_at,
        components: last.components,
      )
    end

    # 合成監視は直近三回の結果から決める（仕様書 3.3）。
    #
    # 失敗しても前回値へは戻さない。届かなかったこと自体が判定の材料であり、
    # 前回値を保つと、一回の失敗を 1 とする上の表が働かなくなる。
    # note はアダプタが返したものをそのまま出すので、失敗の理由を
    # 表示に出したくない取得元は、note を空にして返すこと。
    private def synthetic_status(
      source : SourceRepository,
      observation : Observation,
      history : History,
    ) : ServiceStatus
      latency = observation.latency
      slow = !latency.nil? && latency >= LATENCY_THRESHOLD

      build(
        source,
        level: Usecase.level_for_synthetic(history, degraded: observation.partial? || slow),
        note: observation.note,
        checked_at: observation.checked_at,
        components: observation.components,
      )
    end

    # 表示に出す一件を組み立てる。
    # 名前と URL は取得元から引く。上流の表示名を変えたときに一箇所で済む。
    private def build(
      source : SourceRepository,
      level : Level,
      note : String,
      checked_at : Time,
      components : Array(Component)? = nil,
    ) : ServiceStatus
      ServiceStatus.new(
        id: source.service_id,
        name: source.display_name,
        level: level,
        source: source.source_kind,
        url: source.display_url,
        checked_at: checked_at,
        note: note,
        components: components,
      )
    end

    # 合成監視のレベルを直近三回の結果から決める（仕様書 3.3）。
    #
    # | 直近三回の結果                                     | level |
    # |----------------------------------------------------|-------|
    # | すべて成功                                         | 0     |
    # | 一回失敗、または成功したがレイテンシしきい値を超過 | 1     |
    # | 二回以上失敗                                       | 2     |
    # | bot 検知に相当する応答                             | 3     |
    #
    # degraded は、届いたが一段下げる理由があることを表す。
    # レイテンシの超過と、経路の一部が落ちていること（Observation#partial?）を
    # まとめて受ける。表の二行目はどちらも同じ扱いである。
    #
    # 判定不能を先に見る。bot 検知は失敗とは別の扱いで、赤くしない。
    # 履歴が空のときは今回の結果だけで暫定判定する（仕様書 5.2）。
    def self.level_for_synthetic(history : History, degraded : Bool = false) : Level
      return Level::Unknown if history.indeterminate?

      failures = history.failure_count
      return Level::MajorOutage if failures >= 2
      return Level::Degraded if failures == 1
      return Level::Degraded if degraded

      Level::Operational
    end
  end
end
