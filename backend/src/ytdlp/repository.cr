require "json"
require "log"
require "./models"

# yt-dlp による解決の可否を見る（仕様書 7）。
#
# ワールドの動画プレイヤーで再生できるかは、YouTube のサイト稼働よりも
# yt-dlp が解決できるかに依る。ここはその二段目を担う。
#
# Status::SourceRepository は実装しない。
# 単体で一つのサービスを表すのではなく、youtube/ が oEmbed と組み合わせて
# 使う部品だからである（仕様書 3.3）。
module Ytdlp
  # 検査の結果（仕様書 7.2）。
  enum Outcome
    # 解決できた
    Resolved
    # 解決できなかった
    Failed
    # bot 検知やサインイン要求で、解決できるかを判定できなかった
    Indeterminate
  end

  struct Result
    getter outcome : Outcome
    getter note : String

    def initialize(@outcome : Outcome, @note : String = "")
    end
  end

  class Repository
    Log = ::Log.for("ytdlp")

    # Layer が置く先（仕様書 7.1）。
    BINARY  = "/opt/bin/yt-dlp_linux"
    QUICKJS = "/opt/bin/qjs"

    # /opt は読み取り専用なので、書ける場所へ向ける（仕様書 7.1）。
    # スタンドアロン版は起動のたびに自身を展開するので、その先も同じである。
    WRITABLE  = "/tmp"
    CACHE_DIR = "/tmp/ytdlp"

    ENVIRONMENT = {
      "HOME"   => WRITABLE,
      "TMPDIR" => WRITABLE,
    }

    # 起動から結果までの上限（仕様書 5.2）。
    TIMEOUT = 20.seconds

    # 止めたあと、後始末に付き合う時間。
    #
    # 送った KILL は起動した相手にしか届かない。その相手が作った孫が
    # 出力のパイプを握ったままだと、wait はいつまでも返らない。
    # そこで待ち続けると、上限を置いた意味が消える。
    GRACE = 1.second

    # bot 検知やサインイン要求を示す文言（仕様書 7.2）。
    #
    # yt-dlp はこれを自分で書かず、YouTube が返した理由をそのまま出す
    # （yt_dlp/extractor/youtube/_video.py の playabilityStatus の扱い）。
    # そのため文言を一次情報から固定できない。広く見られる二つを起点に置き、
    # dev で実際に見たものを足していく。
    BOT_DETECTION = [
      "not a bot",
      "sign in to confirm",
    ]

    # 年齢制限は bot 検知ではない。
    #
    # 固定動画は作者自身の公開動画なので（仕様書 3.3）、ここに当たるのは
    # その動画の設定が変わったときである。YouTube の障害ではないから、
    # 判定不能へ逃がさず失敗として残す。
    # 語は yt-dlp 自身が年齢制限の判定に使っているものに合わせた。
    AGE_GATE = [
      "confirm your age",
      "age-restricted",
      "inappropriate",
    ]

    # 上限と実行ファイルの場所を受け取るのは spec から差し替えるためである。
    def initialize(
      @binary : String = BINARY,
      @quickjs : String = QUICKJS,
      @timeout : Time::Span = TIMEOUT,
    )
    end

    # 固定動画を解決してみる。例外は外に出さない（仕様書 11.4）。
    def probe(video_id : String) : Result
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      process = Process.new(
        @binary,
        arguments(video_id),
        env: ENVIRONMENT,
        output: stdout,
        error: stderr,
      )

      status = wait_within(process)
      return Result.new(Outcome::Failed, "yt-dlp が #{@timeout.total_seconds.to_i} 秒で終わらない") if status.nil?
      return judge_output(stdout.to_s) if status.success?

      judge_error(stderr.to_s)
    rescue error
      Result.new(Outcome::Failed, "yt-dlp を起動できない（#{error.class.name}）")
    end

    # 仕様書 7.1 の引数。
    private def arguments(video_id : String) : Array(String)
      [
        "--simulate",
        "-J",
        "--js-runtimes", "quickjs:#{@quickjs}",
        "--cache-dir", CACHE_DIR,
        "--no-warnings",
        "https://www.youtube.com/watch?v=#{video_id}",
      ]
    end

    # 上限まで待ち、越えたら止める（仕様書 5.2）。
    #
    # 止めたあとも少しは待つ。待たずに戻ると、後始末の済んでいない子が
    # ウォームスタートのあいだ溜まっていく。
    # ただし待ち切らない。KILL は起動した相手にしか届かず、その相手が作った
    # 孫がパイプを握っていると wait は返らないままになる。
    private def wait_within(process : Process) : Process::Status?
      done = Channel(Process::Status).new(1)
      spawn { done.send(process.wait) }

      select
      when status = done.receive
        status
      when timeout(@timeout)
        Log.warn { "yt-dlp が終わらないので止める 上限=#{@timeout}" }
        process.signal(Signal::KILL)
        wait_for_exit(done)
        nil
      end
    end

    private def wait_for_exit(done : Channel(Process::Status)) : Nil
      select
      when done.receive
      when timeout(GRACE)
        Log.warn { "yt-dlp を止めたが、終わりを見届けられなかった" }
      end
    end

    # 終了コード 0 でも、formats が空なら解決できていない（仕様書 7.2）。
    private def judge_output(output : String) : Result
      return Result.new(Outcome::Failed, "再生できる形式が無い") if Metadata.from_json(output).formats.empty?

      Result.new(Outcome::Resolved)
    rescue
      Result.new(Outcome::Failed, "yt-dlp の出力が JSON でない")
    end

    private def judge_error(message : String) : Result
      return Result.new(Outcome::Indeterminate, "YouTube が bot 検知を返した") if bot_detection?(message)

      Result.new(Outcome::Failed, summarize(message))
    end

    private def bot_detection?(message : String) : Bool
      lower = message.downcase
      return false if AGE_GATE.any? { |phrase| lower.includes?(phrase) }

      BOT_DETECTION.any? { |phrase| lower.includes?(phrase) }
    end

    # stderr から一行だけ取る。
    # yt-dlp は何行にも渡って出すことがあり、note は一行に収める（仕様書 4）。
    private def summarize(message : String) : String
      message.lines.map(&.strip).find { |line| !line.empty? } || "yt-dlp が失敗した"
    end
  end
end
