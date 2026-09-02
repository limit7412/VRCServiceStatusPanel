require "../spec_helper"

# 決めた結果だけを返す二段目。yt-dlp そのものは spec/ytdlp/ で見る。
private class FakeYtdlp < Ytdlp::Repository
  getter? probed = false

  def initialize(@result : Ytdlp::Result = Ytdlp::Result.new(Ytdlp::Outcome::Resolved))
    super()
  end

  def probe(video_id : String) : Ytdlp::Result
    @probed = true
    @result
  end
end

private def oembed_json : String
  <<-JSON
    { "title": "固定動画", "author_name": "作者" }
    JSON
end

private def with_youtube(
  status : HTTP::Status = HTTP::Status::OK,
  body : String = "",
  ytdlp : FakeYtdlp = FakeYtdlp.new,
  &
)
  queries = [] of String

  handler = ->(context : HTTP::Server::Context) do
    queries << (context.request.query || "")
    context.response.status = status
    context.response.print body
    nil
  end

  with_stub_server(handler) do |endpoint|
    yield Youtube::Repository.new("dQw4w9WgXcQ", ytdlp, endpoint: "#{endpoint}/oembed"), queries
  end
end

describe Youtube::Repository do
  it "合成監視である" do
    Youtube::Repository.new("abc").source_kind.should eq Status::SourceKind::Synthetic
  end

  it "解決の可否で判じていることを名前で示す" do
    Youtube::Repository.new("abc").display_name.should eq "YouTube (yt-dlp解決)"
  end

  it "固定動画の URL を組み立てて渡す" do
    source = Youtube::Repository.new("abc")

    source.watch_url.should eq "https://www.youtube.com/watch?v=abc"
    source.oembed_url.should contain("format=json")
    source.oembed_url.should contain("url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc")
  end

  it "二段とも通れば届いたものとする" do
    with_youtube(body: oembed_json) do |source, queries|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.service_id.should eq "youtube"
      observation.partial?.should be_false
      observation.latency.should_not be_nil
      queries.first.should contain("format=json")
    end
  end

  # サイトは動いているのに解決できない。
  # 再生はできないが YouTube が落ちたわけではない（仕様書 3.3）。
  it "解決できなければ一段下げる" do
    ytdlp = FakeYtdlp.new(Ytdlp::Result.new(Ytdlp::Outcome::Unresolved, "再生できる形式が無い"))

    with_youtube(body: oembed_json, ytdlp: ytdlp) do |source, _|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_true
      observation.note.should eq "再生できる形式が無い"
    end
  end

  # 解決できなかったのと同じ顔をさせると、Layer が載っていない状態が
  # 何日続いても「少し調子が悪い YouTube」としか出ない。
  it "検査そのものが成り立たなければ判定不能とする" do
    ytdlp = FakeYtdlp.new(
      Ytdlp::Result.new(Ytdlp::Outcome::Unavailable, "yt-dlp を起動できない（File::NotFoundError）")
    )

    with_youtube(body: oembed_json, ytdlp: ytdlp) do |source, _|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Indeterminate
      observation.partial?.should be_false
      observation.note.should contain("起動できない")
    end
  end

  # AWS の IP からの取得は bot 検知を受けやすく、避けられない（仕様書 7.4）。
  # 赤くせず判定不能へ逃がす。
  it "bot 検知は判定不能とする" do
    ytdlp = FakeYtdlp.new(
      Ytdlp::Result.new(Ytdlp::Outcome::Indeterminate, "YouTube が bot 検知を返した")
    )

    with_youtube(body: oembed_json, ytdlp: ytdlp) do |source, _|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Indeterminate
      observation.note.should eq "YouTube が bot 検知を返した"
    end
  end

  # サイトが落ちているなら、解決できないのは当たり前で、確かめる意味がない。
  it "一段目が通らなければ二段目を試さない" do
    ytdlp = FakeYtdlp.new

    with_youtube(status: HTTP::Status::NOT_FOUND, ytdlp: ytdlp) do |source, _|
      source.observe.outcome.should eq Status::Outcome::Failure
    end

    ytdlp.probed?.should be_false
  end

  # 消された動画や限定公開では 401 か 404 が返る。
  it "oEmbed が断れば届かなかったものとする" do
    with_youtube(status: HTTP::Status::NOT_FOUND) do |source, _|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.note.should contain("404")
    end
  end

  it "本文が JSON でなければ届かなかったものとする" do
    with_youtube(body: "<html>error</html>") do |source, _|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.note.should eq "oEmbed の応答が JSON でない"
    end
  end

  it "誰も答えなくても例外を外に出さない" do
    source = Youtube::Repository.new(
      "abc",
      FakeYtdlp.new,
      endpoint: "http://127.0.0.1:#{unused_port}/oembed",
    )

    observation = source.observe

    observation.outcome.should eq Status::Outcome::Failure
    # 断られたのではなく届かなかったことが分かるようにする。
    observation.note.should contain("届かない")
  end
end
