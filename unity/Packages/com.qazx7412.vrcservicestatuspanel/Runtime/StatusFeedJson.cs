using UdonSharp;
using UnityEngine;
using VRC.SDK3.Data;

namespace VRCServiceStatusPanel
{
    /// <summary>
    /// 配信JSONの読み方（仕様書 4、8.4）。
    ///
    /// VRCJsonが返すのはDataDictionaryとDataListの入れ子で、値の型は
    /// DataTokenのTokenTypeでしか分からない。想定した型でなければ既定値を返し、
    /// 例外は投げない。UdonSharpにtry/catchが無く、途中で落ちると
    /// パネルが前回値ごと消えるためである。
    ///
    /// UdonSharpがUdonへ変換するのはUdonSharpBehaviourの派生クラスだけなので、
    /// 共通処理は素の静的クラスではなくUdonSharpBehaviourの静的メソッドとして置く。
    /// このクラス自体はコンポーネントとして貼らないため、
    /// AddComponentMenuを空にしてAdd Componentのメニューから外す。
    /// </summary>
    [AddComponentMenu("")]
    [UdonBehaviourSyncMode(BehaviourSyncMode.NoVariableSync)]
    public class StatusFeedJson : UdonSharpBehaviour
    {
        /// <summary>
        /// このアセットが読めるスキーマ版（仕様書 4 の v）。
        /// これ以外が来たらパネルは「アセットの更新が必要」を出す（仕様書 8.2）。
        /// </summary>
        public const int SchemaVersion = 1;

        /// <summary>
        /// 配信JSONをDataDictionaryとして読む。読めなければnullを返す。
        ///
        /// 取得に成功しても本文がJSONとは限らない。配信経路が
        /// エラーページを返した場合もここへ来る。
        /// </summary>
        public static DataDictionary ParseObject(string json)
        {
            if (json == null || json.Length == 0)
            {
                return null;
            }

            if (!VRCJson.TryDeserializeFromJson(json, out DataToken root))
            {
                return null;
            }

            if (root.TokenType != TokenType.DataDictionary)
            {
                return null;
            }

            return root.DataDictionary;
        }

        /// <summary>
        /// 読めるスキーマ版か（仕様書 8.2）。
        /// vが無い場合も読めないものとして扱う。
        /// </summary>
        public static bool IsSupportedVersion(DataDictionary feed)
        {
            return ReadInt(feed, "v", -1) == SchemaVersion;
        }

        /// <summary>
        /// 文字列を取り出す。無い場合と型が違う場合は空文字を返す（仕様書 8.4）。
        /// </summary>
        public static string ReadString(DataDictionary source, string key)
        {
            if (source == null)
            {
                return "";
            }

            if (!source.TryGetValue(key, out DataToken token))
            {
                return "";
            }

            if (token.TokenType != TokenType.String)
            {
                return "";
            }

            return token.String;
        }

        /// <summary>
        /// doubleが整数を正確に表せる限界（2^53）。
        ///
        /// これを超えた値は、解析した時点で入力とは別の値になっている。
        /// 9223372036854775809 は -2^63 へ、9223372036854775808 も 2^63 へ丸められ、
        /// 元の値には戻せない。境界をいくら細かく見ても、丸めた結果を見ているだけである。
        /// この線で切れば、どちらの側の丸めもまとめて落ちる。
        ///
        /// 配信JSONに入る数値はレベル、スキーマ版、epoch秒だけで、
        /// epoch秒がこの線に届くのは二億年以上先である。
        /// </summary>
        private const double ExactIntegerLimit = 9007199254740992.0;

        /// <summary>
        /// 整数としてそのまま受け取れる値か。
        ///
        /// 小数を弾くのは、vが1.5でもintへ落とすと1になり、対応版として
        /// 通ってしまうためである（仕様書 8.2）。
        /// NaNと無限大も剰余がNaNになるため、ここで落ちる。
        /// </summary>
        private static bool IsWhole(double value)
        {
            if (value % 1.0 != 0.0)
            {
                return false;
            }

            return value >= -ExactIntegerLimit && value <= ExactIntegerLimit;
        }

        /// <summary>
        /// 整数を取り出す。
        ///
        /// VRCJsonは数値をすべてDoubleにするため、Doubleとして取ってから変換する
        /// （仕様書 8.4）。無い場合、型が違う場合、整数として受け取れない場合は
        /// fallbackを返す。
        /// </summary>
        public static int ReadInt(DataDictionary source, string key, int fallback)
        {
            if (source == null)
            {
                return fallback;
            }

            if (!source.TryGetValue(key, out DataToken token))
            {
                return fallback;
            }

            if (token.TokenType != TokenType.Double)
            {
                return fallback;
            }

            // 桁が大きすぎるものも弾く。Udonは既定でオーバーフローを検査するので、
            // そのまま変換すると例外になり、パネルが前回値ごと消える。
            double value = token.Double;
            if (!IsWhole(value) || value < int.MinValue || value > int.MaxValue)
            {
                return fallback;
            }

            return (int)value;
        }

        /// <summary>
        /// epoch秒を取り出す。無い場合と型が違う場合は0を返す。
        ///
        /// 時刻の解析は行わない。経過時間はこの値と
        /// DateTimeOffset.UtcNow.ToUnixTimeSeconds()の差で出す（仕様書 8.4）。
        /// </summary>
        public static long ReadUnixSeconds(DataDictionary source, string key)
        {
            if (source == null)
            {
                return 0;
            }

            if (!source.TryGetValue(key, out DataToken token))
            {
                return 0;
            }

            if (token.TokenType != TokenType.Double)
            {
                return 0;
            }

            double value = token.Double;
            if (!IsWhole(value))
            {
                return 0;
            }

            return (long)value;
        }

        /// <summary>
        /// 真偽値を取り出す。無い場合と型が違う場合はfalseを返す。
        /// </summary>
        public static bool ReadBool(DataDictionary source, string key)
        {
            if (source == null)
            {
                return false;
            }

            if (!source.TryGetValue(key, out DataToken token))
            {
                return false;
            }

            if (token.TokenType != TokenType.Boolean)
            {
                return false;
            }

            return token.Boolean;
        }

        /// <summary>
        /// 配列を取り出す。無い場合と型が違う場合はnullを返す。
        /// </summary>
        public static DataList ReadArray(DataDictionary source, string key)
        {
            if (source == null)
            {
                return null;
            }

            if (!source.TryGetValue(key, out DataToken token))
            {
                return null;
            }

            if (token.TokenType != TokenType.DataList)
            {
                return null;
            }

            return token.DataList;
        }

        /// <summary>
        /// 配列の要素をオブジェクトとして取り出す。
        /// 範囲外と型違いはnullを返す。
        /// </summary>
        public static DataDictionary ObjectAt(DataList list, int index)
        {
            if (list == null)
            {
                return null;
            }

            if (index < 0 || index >= list.Count)
            {
                return null;
            }

            DataToken token = list[index];
            if (token.TokenType != TokenType.DataDictionary)
            {
                return null;
            }

            return token.DataDictionary;
        }

        /// <summary>
        /// 表示するサービスの数（仕様書 4 の services）。
        /// servicesが無ければ0になる。
        /// </summary>
        public static int ServiceCount(DataDictionary feed)
        {
            DataList services = ReadArray(feed, "services");
            if (services == null)
            {
                return 0;
            }

            return services.Count;
        }

        /// <summary>
        /// レベルを取り出す（仕様書 8.4）。
        /// 無い場合と型が違う場合はUnknownにする。緑や赤を誤って出さないため。
        /// </summary>
        public static int ReadLevel(DataDictionary service)
        {
            return ReadInt(service, "level", ServiceStatusLevel.Unknown);
        }
    }
}
