using UdonSharp;
using UnityEngine;

namespace ServiceStatusPanel
{
    /// <summary>
    /// 障害レベルの定義と、レベルを扱う共通処理を置く。
    ///
    /// UdonSharpがUdonへ変換するのはUdonSharpBehaviourの派生クラスだけなので、
    /// 共通処理は素の静的クラスではなくUdonSharpBehaviourの静的メソッドとして置く。
    /// このクラス自体はコンポーネントとして貼らないため、
    /// AddComponentMenuを空にしてAdd Componentのメニューから外す。
    /// </summary>
    [AddComponentMenu("")]
    [UdonBehaviourSyncMode(BehaviourSyncMode.NoVariableSync)]
    public class ServiceStatus : UdonSharpBehaviour
    {
        /// <summary>
        /// 状態を取得できていない。
        ///
        /// 値は0で、既知のどのレベルよりも小さい。
        /// 取得できていないことを障害として扱わないため、WorstLevelの結果を押し上げない。
        /// 「一部だけ取得できていない」ことを表示したい場合はAnyUnknownを併用する。
        /// </summary>
        public const int LevelUnknown = 0;

        /// <summary>正常</summary>
        public const int LevelOperational = 1;

        /// <summary>メンテナンス中</summary>
        public const int LevelMaintenance = 2;

        /// <summary>性能低下</summary>
        public const int LevelDegraded = 3;

        /// <summary>一部障害</summary>
        public const int LevelPartialOutage = 4;

        /// <summary>重大障害</summary>
        public const int LevelMajorOutage = 5;

        /// <summary>
        /// statuspage.ioの status.indicator を障害レベルへ変換する。
        ///
        /// 比較は完全一致で行う。statuspage.ioが返す値は小文字で固定されているため、
        /// 大文字小文字の吸収は行わない。表記が変わった場合はUnknownへ落ちる。
        /// </summary>
        public static int LevelFromIndicator(string indicator)
        {
            if (indicator == "none")
            {
                return LevelOperational;
            }

            if (indicator == "maintenance")
            {
                return LevelMaintenance;
            }

            if (indicator == "minor")
            {
                return LevelDegraded;
            }

            if (indicator == "major")
            {
                return LevelPartialOutage;
            }

            if (indicator == "critical")
            {
                return LevelMajorOutage;
            }

            return LevelUnknown;
        }

        /// <summary>
        /// 複数サービスのレベルから、パネル全体として表示するレベルを決める。
        ///
        /// 最も重いレベルを返す。1件も無い場合はUnknownを返す。
        /// </summary>
        public static int WorstLevel(int[] levels)
        {
            if (levels == null)
            {
                return LevelUnknown;
            }

            int worst = LevelUnknown;
            for (int index = 0; index < levels.Length; index++)
            {
                if (levels[index] > worst)
                {
                    worst = levels[index];
                }
            }

            return worst;
        }

        /// <summary>
        /// 状態を取得できていないサービスが含まれるかを返す。
        ///
        /// WorstLevelはUnknownを無視するため、全体としては正常に見えていても
        /// 取得できていないサービスが残っていることがある。その判定に使う。
        /// </summary>
        public static bool AnyUnknown(int[] levels)
        {
            if (levels == null)
            {
                return false;
            }

            for (int index = 0; index < levels.Length; index++)
            {
                if (levels[index] == LevelUnknown)
                {
                    return true;
                }
            }

            return false;
        }
    }
}
