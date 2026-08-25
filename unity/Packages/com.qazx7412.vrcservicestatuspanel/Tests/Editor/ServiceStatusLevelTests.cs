using NUnit.Framework;
using UnityEngine;

namespace VRCServiceStatusPanel.Tests
{
    public class ServiceStatusLevelTests
    {
        [Test]
        public void Levels_MatchTheNumbersOfTheFeed()
        {
            Assert.That(ServiceStatusLevel.Operational, Is.EqualTo(0));
            Assert.That(ServiceStatusLevel.Degraded, Is.EqualTo(1));
            Assert.That(ServiceStatusLevel.MajorOutage, Is.EqualTo(2));
            Assert.That(ServiceStatusLevel.Unknown, Is.EqualTo(3));
        }

        [Test]
        public void ToColor_GivesADistinctColorToEachLevel()
        {
            Color[] colors =
            {
                ServiceStatusLevel.ToColor(ServiceStatusLevel.Operational),
                ServiceStatusLevel.ToColor(ServiceStatusLevel.Degraded),
                ServiceStatusLevel.ToColor(ServiceStatusLevel.MajorOutage),
                ServiceStatusLevel.ToColor(ServiceStatusLevel.Unknown),
            };

            for (int left = 0; left < colors.Length; left++)
            {
                for (int right = left + 1; right < colors.Length; right++)
                {
                    Assert.That(colors[left], Is.Not.EqualTo(colors[right]));
                }
            }
        }

        [Test]
        public void ToColor_FallsBackToTheUnknownColorForAnUnexpectedLevel()
        {
            Color unknown = ServiceStatusLevel.ToColor(ServiceStatusLevel.Unknown);

            Assert.That(ServiceStatusLevel.ToColor(4), Is.EqualTo(unknown));
            Assert.That(ServiceStatusLevel.ToColor(-1), Is.EqualTo(unknown));
        }

        [Test]
        public void IsKnown_AcceptsOnlyTheLevelsOfTheSpecification()
        {
            Assert.That(ServiceStatusLevel.IsKnown(ServiceStatusLevel.Operational), Is.True);
            Assert.That(ServiceStatusLevel.IsKnown(ServiceStatusLevel.Unknown), Is.True);
            Assert.That(ServiceStatusLevel.IsKnown(4), Is.False);
            Assert.That(ServiceStatusLevel.IsKnown(-1), Is.False);
        }
    }
}
