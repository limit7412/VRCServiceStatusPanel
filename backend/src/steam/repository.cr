require "../status/models"
require "../status/repository"
require "../upstream"
require "./models"

module Steam
  # Steam の合成監視（仕様書 3.3）。
  #
  # VRChat の Steam ログインに効くのは Web API 側なので、そちらを主指標にする。
  # ストアは補助で、落ちていても一段下げるにとどめる。ストアが重いだけで
  # ログインできない、とは限らないためである。
  #
  # 非公式のステータス集約サイトは取得元にしない（仕様書 3.3）。
  class Repository < Status::SourceRepository
    # API キーが要らない疎通確認用のエンドポイント。
    WEB_API_URL = "https://api.steampowered.com/ISteamWebAPIUtil/GetServerInfo/v1/"
    STORE_URL   = "https://store.steampowered.com/"

    # 取得先を受け取るのは spec から差し替えるためである。
    # 表示に出す url は上の定数のままにする（仕様書 4）。
    def initialize(
      @web_api_url : String = WEB_API_URL,
      @store_url : String = STORE_URL,
    )
    end

    def service_id : String
      "steam"
    end

    def display_name : String
      "Steam"
    end

    # 人が開くのはストアである。Web API を開いても JSON が出るだけになる。
    def display_url : String
      STORE_URL
    end

    def source_kind : Status::SourceKind
      Status::SourceKind::Synthetic
    end

    # 失敗を例外として外に出さず、outcome で返す（仕様書 11.4）。
    def observe : Status::Observation
      started = Time.instant
      web_api, store = Upstream.get_all([@web_api_url, @store_url])

      # 二つを並べて叩いているので、これは遅いほうの時間である。
      # どちらかが遅ければ利用者の体感も遅いので、主指標だけを測り直さない。
      latency = Time.instant - started

      return failure("Web API が応答しない（#{Upstream.reason(web_api)}）") unless alive?(web_api)

      store_down = !Upstream.ok?(store)

      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Success,
        checked_at: Time.utc,
        latency: latency,
        note: store_down ? "ストアが応答しない（#{Upstream.reason(store)}）" : "",
        partial: store_down,
      )
    rescue error
      failure(error.message || error.class.name)
    end

    # 200 で、しかも読める JSON が返ることまでを見る。
    # 上流がエラーページを 200 で返すことがあり、状態コードだけでは足りない。
    private def alive?(result : HTTP::Client::Response | Exception) : Bool
      return false unless Upstream.ok?(result)
      return false unless result.is_a?(HTTP::Client::Response)

      ServerInfo.from_json(result.body)
      true
    rescue
      false
    end

    # 合成監視の失敗は前回値へ戻らず、この note がそのまま表示に出る。
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
