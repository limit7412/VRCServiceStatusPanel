require "file_utils"
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
  #
  # 解決できなかったことと、検査そのものが成り立たなかったことを分ける。
  # 前者は YouTube 側の話で、後者はこちら側の話である。
  # 同じ扱いにすると、Layer が載っていない状態が何日続いても、
  # パネルには「少し調子が悪い YouTube」としか出ない。
  enum Outcome
    # 解決できた
    Resolved
    # 解決できなかった。動画が消えた、形式が無い、など
    Unresolved
    # 検査そのものが成り立たなかった。起動できない、終わらない、出力が読めない
    Unavailable
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
    #
    # キャッシュだけは実行をまたいで使い回す。毎回捨てると、置いた意味がない。
    CACHE_DIR = "/tmp/ytdlp"

    # 起動から結果までの上限（仕様書 5.2）。
    TIMEOUT = 20.seconds

    # 止めたあと、後始末に付き合う時間。
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
    #
    # 実行ごとに置き場所を作り、終わったら畳む。
    # スタンドアロン版は起動のたびに自身を TMPDIR へ展開し、途中で止められると
    # その展開物を残す。毎分それが続けば、ウォームな環境の /tmp が埋まって、
    # やがて何も検査できなくなる。
    def probe(video_id : String) : Result
      workspace = File.tempname("ytdlp-run")

      begin
        Dir.mkdir_p(workspace)
      rescue error
        # /tmp が埋まっている、書けない。検査を始める前に終わっている。
        return Result.new(Outcome::Unavailable, "置き場所を作れない（#{error.class.name}）")
      end

      begin
        run(video_id, workspace)
      ensure
        discard(workspace)
      end
    end

    # 畳めなくても、そこで実行を終わらせない。
    # 置き場所が残るのは困るが、それを理由に観測を落とすほどではない。
    private def discard(workspace : String) : Nil
      FileUtils.rm_rf(workspace)
    rescue error
      Log.warn(exception: error) { "置き場所を畳めなかった #{workspace}" }
    end

    private def run(video_id : String, workspace : String) : Result
      stdout = IO::Memory.new
      stderr = IO::Memory.new

      process = Process.new(
        @binary,
        arguments(video_id),
        env: {"HOME" => workspace, "TMPDIR" => workspace},
        output: stdout,
        error: stderr,
      )

      status = wait_within(process)
      if status.nil?
        return Result.new(Outcome::Unavailable, "yt-dlp が #{@timeout.total_seconds.to_i} 秒で終わらない")
      end
      return judge_output(stdout.to_s) if status.success?

      judge_error(stderr.to_s)
    rescue error
      Result.new(Outcome::Unavailable, "yt-dlp を起動できない（#{error.class.name}）")
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
    private def wait_within(process : Process) : Process::Status?
      done = Channel(Process::Status).new(1)
      spawn { done.send(process.wait) }

      select
      when status = done.receive
        status
      when timeout(@timeout)
        Log.warn { "yt-dlp が終わらないので止める 上限=#{@timeout}" }
        kill_tree(process.pid)
        wait_for_exit(done)
        nil
      end
    end

    # 起動した相手と、その下にぶら下がったものをまとめて止める。
    #
    # signal が届くのは起動した相手だけである。yt-dlp のスタンドアロン版は
    # 自身を /tmp へ展開してそちらを実行し、そこから QuickJS も起こすので、
    # 相手の下に子が生まれる。親だけを止めると、子は出力のパイプを握ったまま
    # 残り、毎分の実行でウォームな環境に溜まっていく。
    #
    # プロセスグループを分けて一度に落とす手もあるが、Crystal の Process に
    # その口が無い。/proc から子を辿って集め、下から順に止める。
    private def kill_tree(pid : Int64) : Nil
      queue = [pid]
      seen = [] of Int64

      until queue.empty?
        current = queue.shift
        next if seen.includes?(current)

        seen << current

        # 子を控えてから止める。
        # 先に止めると、その子は引き取り手へ移って辿れなくなる。
        # 逆に、控えてから止めるまでの隙に生まれた子は取りこぼす。
        # 取り切るにはプロセスグループが要るが、そこへ届く口が無い。
        queue.concat(children_of(current))
        kill(current)
      end
    end

    # Linux が見せている子の一覧。読めなければ空として扱う。
    private def children_of(pid : Int64) : Array(Int64)
      File.read("/proc/#{pid}/task/#{pid}/children").split.compact_map(&.to_i64?)
    rescue
      [] of Int64
    end

    # 止めた相手は、引き取り手が刈り取るまで PID の表に残ることがある。
    # 動いてはおらず、握っていたパイプも閉じているので、そこまでは追わない。
    private def kill(pid : Int64) : Nil
      Process.signal(Signal::KILL, pid)
    rescue
      # もう終わっている。
    end

    # 止めたあとも少しは待つ。待たずに戻ると、後始末の済んでいない子が残る。
    # ただし待ち切らない。取りこぼした孫がパイプを握っていれば wait は返らず、
    # そこで待ち続けると上限を置いた意味が消える。
    private def wait_for_exit(done : Channel(Process::Status)) : Nil
      select
      when done.receive
      when timeout(GRACE)
        Log.warn { "yt-dlp を止めたが、終わりを見届けられなかった" }
      end
    end

    # 終了コード 0 でも、formats が空なら解決できていない（仕様書 7.2）。
    private def judge_output(output : String) : Result
      return Result.new(Outcome::Unresolved, "再生できる形式が無い") if Metadata.from_json(output).formats.empty?

      Result.new(Outcome::Resolved)
    rescue
      # 終わったのに読めるものが出ていない。動画の話ではなく、検査の話である。
      Result.new(Outcome::Unavailable, "yt-dlp の出力が JSON でない")
    end

    # 終了コードが 0 でない失敗を分ける。
    #
    # bot 検知だけを分け、残りは解決できなかったものとして扱う。
    # yt-dlp 自身の不調（引数の取り違え、QuickJS の欠落）もここへ落ちるが、
    # stderr の文面で見分けようとすると、上流の言い回しが変わるたびに崩れる。
    # 見分けが要るほど頻れば、そのとき文言を足す。
    private def judge_error(message : String) : Result
      return Result.new(Outcome::Indeterminate, "YouTube が bot 検知を返した") if bot_detection?(message)

      Result.new(Outcome::Unresolved, summarize(message))
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
