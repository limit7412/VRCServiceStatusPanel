require "../spec_helper"

# 二つの経路をパスで分ける。片方だけを落とした場合を作るためである。
private record Stub, status : HTTP::Status = HTTP::Status::OK, body : String = ""

private def server_info_json : String
  <<-JSON
    { "servertime": 1756123200, "servertimestring": "Mon Aug 25 21:00:00 2025" }
    JSON
end

private def with_steam(web_api : Stub, store : Stub, &)
  handler = ->(context : HTTP::Server::Context) do
    stub = context.request.path.starts_with?("/api") ? web_api : store
    context.response.status = stub.status
    context.response.print stub.body
    nil
  end

  with_stub_server(handler) do |endpoint|
    yield Steam::Repository.new(
      web_api_url: "#{endpoint}/api",
      store_url: "#{endpoint}/store",
    )
  end
end

describe Steam::Repository do
  it "合成監視である" do
    Steam::Repository.new.source_kind.should eq Status::SourceKind::Synthetic
  end

  it "人が開く先はストアにする" do
    Steam::Repository.new.display_url.should eq Steam::Repository::STORE_URL
  end

  it "どちらも返れば届いたものとする" do
    with_steam(Stub.new(body: server_info_json), Stub.new) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.service_id.should eq "steam"
      observation.partial?.should be_false
      observation.note.should eq ""
      observation.latency.should_not be_nil
    end
  end

  # ストアが重いだけでログインできないとは限らないので、一段下げるにとどめる。
  it "ストアだけが落ちていれば一段下げる" do
    store = Stub.new(status: HTTP::Status::SERVICE_UNAVAILABLE)

    with_steam(Stub.new(body: server_info_json), store) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_true
      observation.note.should contain("ストア")
      observation.note.should contain("503")
    end
  end

  # VRChat の Steam ログインに効くのはこちらである。
  it "Web API が落ちていれば届かなかったものとする" do
    with_steam(Stub.new(status: HTTP::Status::INTERNAL_SERVER_ERROR), Stub.new) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.note.should contain("Web API")
      observation.note.should contain("500")
    end
  end

  # 上流がエラーページを 200 で返すことがある。状態コードだけでは足りない。
  #
  # このとき「HTTP 200」とだけ残すと、応答があったことしか伝わらない。
  # 返ってきたものが読めなかったのだと分かる一行を出す。
  it "Web API が JSON を返さなければ届かなかったものとする" do
    with_steam(Stub.new(body: "<html>maintenance</html>"), Stub.new) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.note.should eq "Web API の応答が JSON でない"
      observation.note.should_not contain("200")
    end
  end

  it "誰も答えなくても例外を外に出さない" do
    port = unused_port
    source = Steam::Repository.new(
      web_api_url: "http://127.0.0.1:#{port}/api",
      store_url: "http://127.0.0.1:#{port}/store",
    )

    observation = source.observe

    observation.outcome.should eq Status::Outcome::Failure
    # 断られたのではなく届かなかったことが分かるようにする。
    observation.note.should contain("届かない")
  end
end
