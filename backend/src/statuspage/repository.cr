require "http/headers"
require "../status/models"
require "../status/repository"
require "../upstream"
require "./models"

module Statuspage
  # Statuspage 系の取得元（仕様書 3.2）。
  #
  # サービスごとに変わるのは id、表示名、ページの URL、表示する component の
  # 名前だけで、取得と判定は共通である。取得元を増やすときは、この四つを渡して
  # 作るだけで済む（仕様書 11.6）。
  class Repository < Status::SourceRepository
    getter service_id : String
    getter display_name : String
    getter page_url : String

    # 前回の ETag と、そのとき読んだ内容（仕様書 5.4）。
    # 304 では本文が返らないので、ここに残したものから観測を組み立てる。
    # インスタンスはコールドスタート時に一度だけ作るため、この二つは
    # ウォームスタートのあいだ生き続ける（仕様書 11.7）。
    @etag : String?
    @cached : Summary?

    def initialize(
      @service_id : String,
      @display_name : String,
      @page_url : String,
      @component_names : Array(String) = [] of String,
    )
    end

    def source_kind : Status::SourceKind
      Status::SourceKind::Official
    end

    def summary_url : String
      "#{page_url}/api/v2/summary.json"
    end

    # 失敗を例外として外に出さず、outcome で返す（仕様書 11.4）。
    def observe : Status::Observation
      started = Time.instant
      response = Upstream.get(summary_url, conditional_headers)
      latency = Time.instant - started

      summary = summary_from(response)
      return failure("HTTP #{response.status_code}") if summary.nil?

      success(summary, latency)
    rescue error
      failure(error.message || error.class.name)
    end

    # 200 なら読み直し、304 なら前回の内容を使う。
    # それ以外は読むものが無いので nil を返す。
    #
    # 304 で控えが無いのは、こちらが If-None-Match を送っていないのに
    # 上流が 304 を返した場合だけである。このときは取得できなかったものとして扱う。
    private def summary_from(response : HTTP::Client::Response) : Summary?
      case response.status_code
      when 200
        summary = Summary.from_json(response.body)
        @etag = response.headers["ETag"]?
        @cached = summary
        summary
      when 304
        @cached
      end
    end

    # 前回の ETag があれば条件付き GET にする（仕様書 5.4）。
    private def conditional_headers : HTTP::Headers
      headers = HTTP::Headers.new
      if etag = @etag
        headers["If-None-Match"] = etag
      end
      headers
    end

    private def success(summary : Summary, latency : Time::Span) : Status::Observation
      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Success,
        checked_at: Time.utc,
        latency: latency,
        note: summary.note,
        components: summary.components_for(@component_names),
        level: Statuspage.level_of(summary.indicator),
      )
    end

    # 失敗したサービスは前回の level と note を引き継ぐ（仕様書 5.3）ので、
    # ここで返す note は表示には出ない。ログに何が起きたかを残すために付ける。
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
