require "./models"
require "./repository"

module Status
  class Usecase
    # 合成監視のレイテンシしきい値と接続タイムアウト（仕様書 3.3）。
    LATENCY_THRESHOLD = 3.seconds
    CONNECT_TIMEOUT   = 5.seconds

    # 合成監視のレベルを直近三回の結果から決める（仕様書 3.3）。
    #
    # | 直近三回の結果                                     | level |
    # |----------------------------------------------------|-------|
    # | すべて成功                                         | 0     |
    # | 一回失敗、または成功したがレイテンシしきい値を超過 | 1     |
    # | 二回以上失敗                                       | 2     |
    # | bot 検知に相当する応答                             | 3     |
    #
    # 判定不能を先に見る。bot 検知は失敗とは別の扱いで、赤くしない。
    # 履歴が空のときは今回の結果だけで暫定判定する（仕様書 5.2）。
    def self.level_for_synthetic(history : History, latency_exceeded : Bool = false) : Level
      return Level::Unknown if history.indeterminate?

      failures = history.failure_count
      return Level::MajorOutage if failures >= 2
      return Level::Degraded if failures == 1
      return Level::Degraded if latency_exceeded

      Level::Operational
    end
  end
end
