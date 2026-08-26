require "http/client"
require "uri"
require "./status/usecase"

# 上流への GET の共通部分（仕様書 5.4、11.7）。
#
# 取得元アダプタはどれも「名乗りを付けて一度だけ GET する」ところが同じで、
# 違うのは URL と応答の読み方だけである。同じ手続きを取得元の数だけ書き写すと、
# 名乗りや上限の変更がどれか一つで漏れる。
module Upstream
  # shard.yml の版をそのまま使う。名乗りに出す版を二箇所で持たないためである。
  VERSION = {{ read_file("#{__DIR__}/../shard.yml").lines.find(&.starts_with?("version:")).split(": ").last.strip }}

  # 名乗り（仕様書 5.4）。VRChat API を含むすべての上流に同じ値を送る。
  USER_AGENT = "VRCServiceStatusPanel/#{VERSION} (+https://github.com/limit7412/VRCServiceStatusPanel)"

  # 接続と応答待ちの上限（仕様書 3.3、5.2）。
  # 中核が持つ値をそのまま使い、秒数を二箇所に置かない。
  TIMEOUT = Status::Usecase::CONNECT_TIMEOUT

  # 一度だけ GET する。失敗しても再試行しない（仕様書 5.4）。
  #
  # 接続を使い回さないのは、keep-alive が古いレプリカに固定される事象を
  # 避けるためである（仕様書 11.7）。
  def self.get(url : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
    uri = URI.parse(url)

    request_headers = headers.dup
    request_headers["User-Agent"] = USER_AGENT

    client = HTTP::Client.new(uri)
    client.connect_timeout = TIMEOUT
    client.read_timeout = TIMEOUT

    begin
      client.get(request_target(uri), headers: request_headers)
    ensure
      client.close
    end
  end

  # URI からパス以降を取り出す。パスが空のときは "/" にする。
  private def self.request_target(uri : URI) : String
    target = uri.request_target
    target.empty? ? "/" : target
  end
end
