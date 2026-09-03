require "../spec_helper"

private def config_json(version : String = "2025.09.26") : String
  %({"player-url-resolver-version": "#{version}", "player-url-resolver-sha1": "x"})
end

# 呼ばれた回数を数え、決めた応答を返す /config。
private class Upstream
  getter hits = 0
  property status = HTTP::Status::OK
  property body = ""

  def handler : HTTP::Server::Context -> Nil
    ->(context : HTTP::Server::Context) do
      @hits += 1
      context.response.status = @status
      context.response.print @body
      nil
    end
  end
end

describe VrchatApi::Repository do
  it "同梱版の版を返す" do
    upstream = Upstream.new
    upstream.body = config_json

    with_stub_server(upstream.handler) do |endpoint|
      VrchatApi::Repository.new(endpoint).version.should eq "2025.09.26"
    end
  end

  # ライブラリの README は「once per 60 seconds」を上限としている。
  # 60 秒間隔の関数から毎回叩くと、Scheduler の揺らぎで上限を切る。
  it "一時間のあいだは取り直さない" do
    upstream = Upstream.new
    upstream.body = config_json
    at = Time.utc(2026, 9, 3, 0, 0, 0)

    with_stub_server(upstream.handler) do |endpoint|
      source = VrchatApi::Repository.new(endpoint)

      source.version(at)
      source.version(at + 59.minutes)
      upstream.hits.should eq 1

      source.version(at + 60.minutes)
      upstream.hits.should eq 2
    end
  end

  it "取れなければ nil を返し、例外を外に出さない" do
    upstream = Upstream.new
    upstream.status = HTTP::Status::SERVICE_UNAVAILABLE

    with_stub_server(upstream.handler) do |endpoint|
      VrchatApi::Repository.new(endpoint).version.should be_nil
    end

    VrchatApi::Repository.new("http://127.0.0.1:#{unused_port}/config").version.should be_nil
  end

  it "本文が読めなければ nil を返す" do
    upstream = Upstream.new
    upstream.body = "<html>challenge</html>"

    with_stub_server(upstream.handler) do |endpoint|
      VrchatApi::Repository.new(endpoint).version.should be_nil
    end
  end

  # 版が変わるのは稀で、取れなかった一時間だけ照合が消えるより、
  # 古い版で比べ続けるほうが読み手を惑わせない。
  it "取り直しに失敗しても前回の値を残す" do
    upstream = Upstream.new
    upstream.body = config_json
    at = Time.utc(2026, 9, 3, 0, 0, 0)

    with_stub_server(upstream.handler) do |endpoint|
      source = VrchatApi::Repository.new(endpoint)
      source.version(at).should eq "2025.09.26"

      upstream.status = HTTP::Status::SERVICE_UNAVAILABLE
      source.version(at + 1.hour).should eq "2025.09.26"

      # 失敗のあとも、次の一時間までは取り直さない。
      source.version(at + 90.minutes)
      upstream.hits.should eq 2
    end
  end
end
