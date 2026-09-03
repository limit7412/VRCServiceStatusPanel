require "../spec_helper"

# 非公式の OpenAPI 定義（APIConfig）に合わせた本文。
# 実応答はまだ見ていないので、値は定義の例に倣った仮のものである。
# 実応答が取れたら、この本文をそれに差し替える。
private def config_json : String
  <<-JSON
    {
      "clientApiKey": "xxx",
      "player-url-resolver-version": "2025.09.26",
      "player-url-resolver-sha1": "deadbeef",
      "downloadLinkWindows": "https://example.invalid/"
    }
    JSON
end

describe VrchatApi::Config do
  it "同梱版の版とハッシュを読む" do
    config = VrchatApi::Config.from_json(config_json)

    config.player_url_resolver_version.should eq "2025.09.26"
    config.player_url_resolver_sha1.should eq "deadbeef"
  end

  it "版が無ければ読めない" do
    expect_raises(JSON::SerializableError) do
      VrchatApi::Config.from_json(%({"clientApiKey": "xxx"}))
    end
  end
end
