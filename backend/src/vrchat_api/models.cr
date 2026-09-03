require "json"

# VRChat API の応答の写像（仕様書 7.3）。
module VrchatApi
  # `/config` の応答のうち、同梱版の照合に要るところだけ。
  #
  # キー名は非公式の OpenAPI 定義（vrchatapi/specification の APIConfig）から
  # 取った。仕様書 7.3 が想定していた `youtubedl_version` ではない。
  # 応答には他に百を超えるキーがあるが、読まないものは書かない。
  #
  # 値の形式（公式リリースのタグ `2025.09.26` と一致するか）は、定義には
  # 書かれていない。実応答で確かめるまでは、文字列のまま比べる。
  struct Config
    include JSON::Serializable

    @[JSON::Field(key: "player-url-resolver-version")]
    getter player_url_resolver_version : String

    @[JSON::Field(key: "player-url-resolver-sha1")]
    getter player_url_resolver_sha1 : String = ""
  end
end
