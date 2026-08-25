using UdonSharp;
using UnityEngine;

namespace VRCServiceStatusPanel
{
    /// <summary>
    /// 配信JSONの level（仕様書 3.1）と、その表示色（仕様書 8.3）。
    ///
    /// ワールド側はこの数値で色を引くだけで、判定はすべて集約サーバーに置く。
    /// そのため上流の応答をレベルへ写す処理はここには無い。
    ///
    /// UdonSharpがUdonへ変換するのはUdonSharpBehaviourの派生クラスだけなので、
    /// 共通処理は素の静的クラスではなくUdonSharpBehaviourの静的メソッドとして置く。
    /// このクラス自体はコンポーネントとして貼らないため、
    /// AddComponentMenuを空にしてAdd Componentのメニューから外す。
    /// </summary>
    [AddComponentMenu("")]
    [UdonBehaviourSyncMode(BehaviourSyncMode.NoVariableSync)]
    public class ServiceStatusLevel : UdonSharpBehaviour
    {
        /// <summary>正常</summary>
        public const int Operational = 0;

        /// <summary>一部機能の低下、または断続的な失敗</summary>
        public const int Degraded = 1;

        /// <summary>主要機能が利用不能</summary>
        public const int MajorOutage = 2;

        /// <summary>判定できない（取得失敗、bot検知など）</summary>
        public const int Unknown = 3;

        /// <summary>
        /// レベルに対応する表示色を返す（仕様書 8.3）。
        ///
        /// 知らない値はグレーにする。配信JSONのスキーマ版が上がってレベルが
        /// 増えたとき、古いアセットが緑や赤を誤って出さないようにするため。
        /// </summary>
        public static Color ToColor(int level)
        {
            if (level == Operational)
            {
                return new Color(0.30f, 0.69f, 0.31f);
            }

            if (level == Degraded)
            {
                return new Color(0.98f, 0.75f, 0.18f);
            }

            if (level == MajorOutage)
            {
                return new Color(0.90f, 0.30f, 0.24f);
            }

            return new Color(0.62f, 0.62f, 0.62f);
        }

        /// <summary>
        /// 表示できるレベルかどうか。
        /// 知らない値はUnknownとして扱うため、ラベルの選択などで使う。
        /// </summary>
        public static bool IsKnown(int level)
        {
            return level >= Operational && level <= Unknown;
        }
    }
}
