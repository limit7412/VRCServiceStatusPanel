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
        /// 整数を取り出す。
        ///
        /// VRCJsonは数値をすべてDoubleにするため、Doubleとして取ってから変換する
        /// （仕様書 8.4）。無い場合と型が違う場合はfallbackを返す。
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

            return (int)token.Double;
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

            return (long)token.Double;
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
