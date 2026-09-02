require "../spec_helper"

# 決めた出力と終了コードを返す偽の実行ファイルを置き、その場所を渡す。
#
# 本物の yt-dlp は Layer にしか無く、CI にも手元にも無い。
# ここで確かめたいのは起動と後始末と出力の分類であって、
# yt-dlp が YouTube を解決できるかではない。
#
# 出力はファイルへ書いてから読ませる。bot 検知の文言には引用符が入るので、
# スクリプトへ直に埋め込むと、その引用符で壊れる。
private def with_fake_ytdlp(
  stdout : String = "",
  stderr : String = "",
  exit_code : Int32 = 0,
  sleep_seconds : String? = nil,
  &
)
  base = File.tempname("ytdlp-fake")
  out_path = "#{base}.out"
  err_path = "#{base}.err"
  args_path = "#{base}.args"
  tmpdir_path = "#{base}.tmpdir"
  script = "#{base}.sh"

  File.write(out_path, stdout)
  File.write(err_path, stderr)
  fake = String.build do |io|
    io << "#!/bin/sh\n"
    io << %(printf '%s\\n' "$@" > #{args_path}\n)
    # 渡された置き場所を控え、そこへ展開したふりをする。
    io << %(printf '%s' "$TMPDIR" > #{tmpdir_path}\n)
    io << %(mkdir -p "$TMPDIR/_MEI0000"\n)
    io << "sleep #{sleep_seconds}\n" if sleep_seconds
    io << "cat #{out_path}\n"
    io << "cat #{err_path} >&2\n"
    io << "exit #{exit_code}\n"
  end

  File.write(script, fake)
  File.chmod(script, 0o755)

  begin
    yield script, args_path, tmpdir_path
  ensure
    [out_path, err_path, args_path, tmpdir_path, script].each { |path| File.delete?(path) }
  end
end

# 子を残したまま眠る偽物。止めるときに子まで落とせるかを見るために使う。
#
# 本物の yt-dlp はスタンドアロン版で、自身を /tmp へ展開してそちらを実行し、
# QuickJS も別に起こす。親だけを止めても子が残る形は、本番でも起こりうる。
private def with_fake_ytdlp_spawning_child(&)
  base = File.tempname("ytdlp-fake")
  child_path = "#{base}.child"
  tmpdir_path = "#{base}.tmpdir"
  script = "#{base}.sh"

  fake = String.build do |io|
    io << "#!/bin/sh\n"
    io << %(printf '%s' "$TMPDIR" > #{tmpdir_path}\n)
    io << %(mkdir -p "$TMPDIR/_MEI0000"\n)
    io << "sleep 30 &\n"
    io << "echo $! > #{child_path}\n"
    io << "sleep 30\n"
  end

  File.write(script, fake)
  File.chmod(script, 0o755)

  begin
    yield script, child_path, tmpdir_path
  ensure
    [child_path, tmpdir_path, script].each { |path| File.delete?(path) }
  end
end

# 止まるまで少し待つ。KILL が届いても、止まるのは次の瞬間とは限らない。
#
# Process.exists? では見分けられない。あれはシグナルが届くかを見るもので、
# 終わったが引き取り手が刈り取っていないもの（ゾンビ）にも真を返す。
# 動いていないことを見たいので、状態そのものを読む。
private def stopped?(pid : Int64) : Bool
  20.times do
    return true if zombie_or_gone?(pid)
    sleep 20.milliseconds
  end

  zombie_or_gone?(pid)
end

private def zombie_or_gone?(pid : Int64) : Bool
  # /proc の stat は「pid (名前) 状態 ...」で、名前に空白が入りうる。
  File.read("/proc/#{pid}/stat").split(") ").last[0] == 'Z'
rescue
  # 読めないなら、もう居ない。
  true
end

private def metadata_json(formats : Int32 = 1) : String
  entries = Array.new(formats) { |index| %({"format_id": "#{index}"}) }

  %({"id": "abc", "title": "固定動画", "formats": [#{entries.join(",")}]})
end

describe Ytdlp::Repository do
  describe "#probe" do
    it "解決できれば成功とする" do
      with_fake_ytdlp(stdout: metadata_json) do |binary, _, _|
        result = Ytdlp::Repository.new(binary: binary).probe("abc")

        result.outcome.should eq Ytdlp::Outcome::Resolved
      end
    end

    # 仕様書 7.1 の引数をそのまま渡す。
    it "仕様どおりの引数で起動する" do
      with_fake_ytdlp(stdout: metadata_json) do |binary, args_path, _|
        Ytdlp::Repository.new(binary: binary, quickjs: "/opt/bin/qjs").probe("abc")

        args = File.read(args_path).lines.map(&.strip)
        args.should contain "--simulate"
        args.should contain "-J"
        args.should contain "--no-warnings"
        args.should contain "quickjs:/opt/bin/qjs"
        args.should contain Ytdlp::Repository::CACHE_DIR
        args.should contain "https://www.youtube.com/watch?v=abc"
      end
    end

    # 終了コードが 0 でも、再生できる形式が無ければ解決できていない（仕様書 7.2）。
    it "formats が空なら解決できなかったものとする" do
      with_fake_ytdlp(stdout: metadata_json(formats: 0)) do |binary, _, _|
        result = Ytdlp::Repository.new(binary: binary).probe("abc")

        result.outcome.should eq Ytdlp::Outcome::Unresolved
        result.note.should eq "再生できる形式が無い"
      end
    end

    it "出力が JSON でなければ解決できなかったものとする" do
      with_fake_ytdlp(stdout: "not json") do |binary, _, _|
        result = Ytdlp::Repository.new(binary: binary).probe("abc")

        # 終わったのに読めるものが出ていない。動画の話ではなく、検査の話である。
        result.outcome.should eq Ytdlp::Outcome::Unavailable
        result.note.should eq "yt-dlp の出力が JSON でない"
      end
    end

    # AWS の IP からの取得は bot 検知を受けやすい（仕様書 7.4）。
    # 赤くせず判定不能へ逃がす。
    it "bot 検知の文言があれば判定不能とする" do
      message = "ERROR: [youtube] abc: Sign in to confirm you're not a bot. Use --cookies-from-browser"

      with_fake_ytdlp(stderr: message, exit_code: 1) do |binary, _, _|
        result = Ytdlp::Repository.new(binary: binary).probe("abc")

        result.outcome.should eq Ytdlp::Outcome::Indeterminate
      end
    end

    # 年齢制限は YouTube の障害ではなく、固定動画の設定が変わったことを表す。
    # 判定不能へ逃がすと、直すべきものが見えなくなる。
    it "年齢制限は判定不能にしない" do
      message = "ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users."

      with_fake_ytdlp(stderr: message, exit_code: 1) do |binary, _, _|
        result = Ytdlp::Repository.new(binary: binary).probe("abc")

        result.outcome.should eq Ytdlp::Outcome::Unresolved
      end
    end

    it "それ以外の失敗は理由を一行で残す" do
      message = "ERROR: [youtube] abc: Video unavailable\n  Traceback...\n"

      with_fake_ytdlp(stderr: message, exit_code: 1) do |binary, _, _|
        result = Ytdlp::Repository.new(binary: binary).probe("abc")

        result.outcome.should eq Ytdlp::Outcome::Unresolved
        result.note.should eq "ERROR: [youtube] abc: Video unavailable"
      end
    end

    # 一つの取得元が居座ると、その実行では他のサービスも更新できない。
    it "上限を越えたら止める" do
      with_fake_ytdlp(stdout: metadata_json, sleep_seconds: "10") do |binary, _, _|
        started = Time.instant
        result = Ytdlp::Repository.new(binary: binary, timeout: 200.milliseconds).probe("abc")

        # 動画を解決できなかったのではなく、検査が成り立たなかった。
        result.outcome.should eq Ytdlp::Outcome::Unavailable
        result.note.should contain("終わらない")
        # 止めるまでを待つが、眠っている十秒には付き合わない。
        (Time.instant - started).should be < 5.seconds
      end
    end

    # スタンドアロン版は起動のたびに自身を TMPDIR へ展開する。
    # 実行ごとの置き場所を渡して畳まないと、ウォームな環境の /tmp が埋まる。
    it "実行ごとの置き場所を畳む" do
      with_fake_ytdlp(stdout: metadata_json) do |binary, _, tmpdir_path|
        Ytdlp::Repository.new(binary: binary).probe("abc")

        workspace = File.read(tmpdir_path)
        workspace.should_not eq ""
        Dir.exists?(workspace).should be_false
      end
    end

    # 途中で止めると、展開物を片付ける手続きも一緒に消える。畳むのはこちらの仕事になる。
    it "止めたときも置き場所を畳む" do
      with_fake_ytdlp_spawning_child do |binary, _, tmpdir_path|
        Ytdlp::Repository.new(binary: binary, timeout: 300.milliseconds).probe("abc")

        workspace = File.read(tmpdir_path)
        workspace.should_not eq ""
        Dir.exists?(workspace).should be_false
      end
    end

    # 親だけを止めると、子はパイプを握ったまま残り、毎分の実行で溜まっていく。
    it "止めるときは子まで落とす" do
      with_fake_ytdlp_spawning_child do |binary, child_path, _|
        result = Ytdlp::Repository.new(binary: binary, timeout: 300.milliseconds).probe("abc")

        result.outcome.should eq Ytdlp::Outcome::Unavailable

        child = File.read(child_path).strip.to_i64
        stopped?(child).should be_true
      end
    end

    # /tmp が埋まっている、書けない。検査を始める前に終わっている。
    #
    # ここで例外を漏らすと、oEmbed が通っていても YouTube の観測が失敗になり、
    # 二回続けば全断として扱われる。YouTube は何ともなっていないのに。
    it "置き場所を作れなくても例外を外に出さない" do
      original = ENV["TMPDIR"]?
      # /proc の下には作れない。
      ENV["TMPDIR"] = "/proc/cannot-create-here"

      begin
        result = Ytdlp::Repository.new(binary: "/bin/true").probe("abc")

        result.outcome.should eq Ytdlp::Outcome::Unavailable
        result.note.should contain("置き場所")
      ensure
        if original
          ENV["TMPDIR"] = original
        else
          ENV.delete("TMPDIR")
        end
      end
    end

    # Layer が載っていない、名前が変わった、といったときにここへ来る。
    it "実行ファイルが無くても例外を外に出さない" do
      result = Ytdlp::Repository.new(binary: "/nonexistent/yt-dlp").probe("abc")

      result.outcome.should eq Ytdlp::Outcome::Unavailable
      result.note.should contain("起動できない")
    end
  end
end
