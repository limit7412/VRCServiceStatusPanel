using NUnit.Framework;
using VRC.SDK3.Data;

namespace VRCServiceStatusPanel.Tests
{
    public class StatusFeedJsonTests
    {
        // 仕様書 4 の例をそのまま使う。
        private const string FeedJson = @"{
            ""v"": 1,
            ""generated_unix"": 1756123200,
            ""generated_jst"": ""2026/08/25 21:00"",
            ""stale"": false,
            ""services"": [
                {
                    ""id"": ""vrchat"",
                    ""name"": ""VRChat"",
                    ""level"": 1,
                    ""label"": ""Degraded"",
                    ""note"": ""Websocket: Partial Outage"",
                    ""source"": ""official"",
                    ""url"": ""https://status.vrchat.com"",
                    ""checked_unix"": 1756123180
                },
                {
                    ""id"": ""youtube"",
                    ""name"": ""YouTube (yt-dlp解決)"",
                    ""level"": 0,
                    ""label"": ""Operational"",
                    ""note"": """",
                    ""source"": ""synthetic"",
                    ""url"": ""https://www.youtube.com"",
                    ""checked_unix"": 1756123185
                }
            ]
        }";

        private static DataDictionary Feed()
        {
            return StatusFeedJson.ParseObject(FeedJson);
        }

        private static DataDictionary ServiceAt(int index)
        {
            return StatusFeedJson.ObjectAt(StatusFeedJson.ReadArray(Feed(), "services"), index);
        }

        [Test]
        public void ParseObject_ReadsTheFeedOfTheSpecification()
        {
            Assert.That(Feed(), Is.Not.Null);
        }

        [Test]
        public void ParseObject_RefusesAnythingThatIsNotAJsonObject()
        {
            Assert.That(StatusFeedJson.ParseObject(null), Is.Null);
            Assert.That(StatusFeedJson.ParseObject(""), Is.Null);
            Assert.That(StatusFeedJson.ParseObject("<html>error</html>"), Is.Null);
            Assert.That(StatusFeedJson.ParseObject("[1, 2, 3]"), Is.Null);
        }

        [Test]
        public void IsSupportedVersion_AcceptsOnlyTheVersionThisAssetReads()
        {
            Assert.That(StatusFeedJson.SchemaVersion, Is.EqualTo(1));
            Assert.That(StatusFeedJson.IsSupportedVersion(Feed()), Is.True);
            Assert.That(StatusFeedJson.IsSupportedVersion(StatusFeedJson.ParseObject(@"{""v"": 2}")), Is.False);
            Assert.That(StatusFeedJson.IsSupportedVersion(StatusFeedJson.ParseObject("{}")), Is.False);
        }

        [Test]
        public void IsSupportedVersion_RefusesAVersionThatIsNotAWholeNumber()
        {
            // int へ落とすと 1 になるが、これは v1 のフィードではない。
            Assert.That(
                StatusFeedJson.IsSupportedVersion(StatusFeedJson.ParseObject(@"{""v"": 1.5}")),
                Is.False);
        }

        [Test]
        public void ReadInt_RefusesANumberTooLargeToConvert()
        {
            Assert.That(
                StatusFeedJson.IsSupportedVersion(StatusFeedJson.ParseObject(@"{""v"": 1e30}")),
                Is.False);
        }

        [Test]
        public void ReadString_TakesTheHeaderOfTheFeed()
        {
            Assert.That(StatusFeedJson.ReadString(Feed(), "generated_jst"), Is.EqualTo("2026/08/25 21:00"));
        }

        [Test]
        public void ReadString_IsEmptyWhenTheKeyIsMissingOrHasAnotherType()
        {
            DataDictionary feed = Feed();

            Assert.That(StatusFeedJson.ReadString(feed, "nothing"), Is.EqualTo(""));
            Assert.That(StatusFeedJson.ReadString(feed, "generated_unix"), Is.EqualTo(""));
            Assert.That(StatusFeedJson.ReadString(null, "generated_jst"), Is.EqualTo(""));
        }

        [Test]
        public void ReadUnixSeconds_KeepsTheWholeEpochSecond()
        {
            Assert.That(StatusFeedJson.ReadUnixSeconds(Feed(), "generated_unix"), Is.EqualTo(1756123200L));
            Assert.That(StatusFeedJson.ReadUnixSeconds(Feed(), "nothing"), Is.EqualTo(0L));
            Assert.That(StatusFeedJson.ReadUnixSeconds(Feed(), "generated_jst"), Is.EqualTo(0L));
        }

        [Test]
        public void ReadUnixSeconds_RefusesATimeThatIsNotAWholeSecond()
        {
            Assert.That(
                StatusFeedJson.ReadUnixSeconds(
                    StatusFeedJson.ParseObject(@"{""generated_unix"": 1756123200.5}"),
                    "generated_unix"),
                Is.EqualTo(0L));
        }

        [Test]
        public void ReadBool_ReadsStaleAndFallsBackToFalse()
        {
            Assert.That(StatusFeedJson.ReadBool(Feed(), "stale"), Is.False);
            Assert.That(StatusFeedJson.ReadBool(StatusFeedJson.ParseObject(@"{""stale"": true}"), "stale"), Is.True);
            Assert.That(StatusFeedJson.ReadBool(Feed(), "nothing"), Is.False);
            Assert.That(StatusFeedJson.ReadBool(Feed(), "generated_jst"), Is.False);
        }

        [Test]
        public void ReadArray_TakesTheServicesInTheOrderTheyWereSent()
        {
            DataList services = StatusFeedJson.ReadArray(Feed(), "services");

            Assert.That(services, Is.Not.Null);
            Assert.That(services.Count, Is.EqualTo(2));
            Assert.That(StatusFeedJson.ReadString(StatusFeedJson.ObjectAt(services, 0), "id"), Is.EqualTo("vrchat"));
            Assert.That(StatusFeedJson.ReadString(StatusFeedJson.ObjectAt(services, 1), "id"), Is.EqualTo("youtube"));
        }

        [Test]
        public void ReadArray_IsNullWhenTheKeyIsMissingOrHasAnotherType()
        {
            Assert.That(StatusFeedJson.ReadArray(Feed(), "nothing"), Is.Null);
            Assert.That(StatusFeedJson.ReadArray(Feed(), "generated_jst"), Is.Null);
        }

        [Test]
        public void ObjectAt_RefusesAnIndexOutsideTheArray()
        {
            DataList services = StatusFeedJson.ReadArray(Feed(), "services");

            Assert.That(StatusFeedJson.ObjectAt(services, -1), Is.Null);
            Assert.That(StatusFeedJson.ObjectAt(services, 2), Is.Null);
            Assert.That(StatusFeedJson.ObjectAt(null, 0), Is.Null);
        }

        [Test]
        public void ObjectAt_RefusesAnElementThatIsNotAnObject()
        {
            DataList mixed = StatusFeedJson.ReadArray(
                StatusFeedJson.ParseObject(@"{""services"": [1, ""two""]}"),
                "services");

            Assert.That(StatusFeedJson.ObjectAt(mixed, 0), Is.Null);
            Assert.That(StatusFeedJson.ObjectAt(mixed, 1), Is.Null);
        }

        [Test]
        public void ServiceCount_CountsTheRowsToShow()
        {
            Assert.That(StatusFeedJson.ServiceCount(Feed()), Is.EqualTo(2));
            Assert.That(StatusFeedJson.ServiceCount(StatusFeedJson.ParseObject("{}")), Is.EqualTo(0));
            Assert.That(StatusFeedJson.ServiceCount(null), Is.EqualTo(0));
        }

        [Test]
        public void ReadLevel_TakesTheNumberOfTheRow()
        {
            Assert.That(StatusFeedJson.ReadLevel(ServiceAt(0)), Is.EqualTo(ServiceStatusLevel.Degraded));
            Assert.That(StatusFeedJson.ReadLevel(ServiceAt(1)), Is.EqualTo(ServiceStatusLevel.Operational));
        }

        [Test]
        public void ReadLevel_FallsBackToUnknownWhenTheRowDoesNotCarryOne()
        {
            Assert.That(
                StatusFeedJson.ReadLevel(StatusFeedJson.ParseObject(@"{""level"": ""1""}")),
                Is.EqualTo(ServiceStatusLevel.Unknown));
            Assert.That(
                StatusFeedJson.ReadLevel(StatusFeedJson.ParseObject("{}")),
                Is.EqualTo(ServiceStatusLevel.Unknown));
            Assert.That(
                StatusFeedJson.ReadLevel(StatusFeedJson.ParseObject(@"{""level"": 1.5}")),
                Is.EqualTo(ServiceStatusLevel.Unknown));
            Assert.That(StatusFeedJson.ReadLevel(null), Is.EqualTo(ServiceStatusLevel.Unknown));
        }

        [Test]
        public void ReadString_KeepsTheNoteAsTheServerFormattedIt()
        {
            Assert.That(StatusFeedJson.ReadString(ServiceAt(0), "note"), Is.EqualTo("Websocket: Partial Outage"));
            Assert.That(StatusFeedJson.ReadString(ServiceAt(1), "note"), Is.EqualTo(""));
            Assert.That(StatusFeedJson.ReadString(ServiceAt(1), "source"), Is.EqualTo("synthetic"));
        }
    }
}
