require "json"

# yt-dlp の出力の写像（仕様書 7.2）。
module Ytdlp
  # `-J` が出すメタデータのうち、解決できたことを示す部分だけ。
  #
  # formats が空でなければ解決できている。中身までは見ない。
  # どの形式で再生するかはワールド側の都合であって、こちらの判定には要らない。
  struct Metadata
    include JSON::Serializable

    getter formats : Array(Format) = [] of Format
  end

  struct Format
    include JSON::Serializable

    getter format_id : String = ""
  end
end
