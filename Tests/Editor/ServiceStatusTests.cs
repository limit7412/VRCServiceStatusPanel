using NUnit.Framework;

namespace ServiceStatusPanel.Tests
{
    public class ServiceStatusTests
    {
        [Test]
        public void LevelFromIndicator_MapsKnownIndicators()
        {
            Assert.That(ServiceStatus.LevelFromIndicator("none"), Is.EqualTo(ServiceStatus.LevelOperational));
            Assert.That(ServiceStatus.LevelFromIndicator("maintenance"), Is.EqualTo(ServiceStatus.LevelMaintenance));
            Assert.That(ServiceStatus.LevelFromIndicator("minor"), Is.EqualTo(ServiceStatus.LevelDegraded));
            Assert.That(ServiceStatus.LevelFromIndicator("major"), Is.EqualTo(ServiceStatus.LevelPartialOutage));
            Assert.That(ServiceStatus.LevelFromIndicator("critical"), Is.EqualTo(ServiceStatus.LevelMajorOutage));
        }

        [Test]
        public void LevelFromIndicator_UnknownIndicatorFallsBackToUnknown()
        {
            Assert.That(ServiceStatus.LevelFromIndicator("NONE"), Is.EqualTo(ServiceStatus.LevelUnknown));
            Assert.That(ServiceStatus.LevelFromIndicator(""), Is.EqualTo(ServiceStatus.LevelUnknown));
            Assert.That(ServiceStatus.LevelFromIndicator(null), Is.EqualTo(ServiceStatus.LevelUnknown));
        }

        [Test]
        public void LevelFromIndicator_OrdersIndicatorsBySeverity()
        {
            Assert.That(
                ServiceStatus.LevelFromIndicator("critical"),
                Is.GreaterThan(ServiceStatus.LevelFromIndicator("major")));
            Assert.That(
                ServiceStatus.LevelFromIndicator("major"),
                Is.GreaterThan(ServiceStatus.LevelFromIndicator("minor")));
            Assert.That(
                ServiceStatus.LevelFromIndicator("minor"),
                Is.GreaterThan(ServiceStatus.LevelFromIndicator("none")));
        }

        [Test]
        public void WorstLevel_ReturnsHeaviestLevel()
        {
            int[] levels =
            {
                ServiceStatus.LevelOperational,
                ServiceStatus.LevelPartialOutage,
                ServiceStatus.LevelDegraded,
            };

            Assert.That(ServiceStatus.WorstLevel(levels), Is.EqualTo(ServiceStatus.LevelPartialOutage));
        }

        [Test]
        public void WorstLevel_IgnoresUnknown()
        {
            int[] levels = { ServiceStatus.LevelUnknown, ServiceStatus.LevelOperational };

            Assert.That(ServiceStatus.WorstLevel(levels), Is.EqualTo(ServiceStatus.LevelOperational));
        }

        [Test]
        public void WorstLevel_WithoutEntriesIsUnknown()
        {
            Assert.That(ServiceStatus.WorstLevel(new int[0]), Is.EqualTo(ServiceStatus.LevelUnknown));
            Assert.That(ServiceStatus.WorstLevel(null), Is.EqualTo(ServiceStatus.LevelUnknown));
        }

        [Test]
        public void AnyUnknown_DetectsMissingStatus()
        {
            int[] withUnknown = { ServiceStatus.LevelOperational, ServiceStatus.LevelUnknown };
            int[] withoutUnknown = { ServiceStatus.LevelOperational, ServiceStatus.LevelMajorOutage };

            Assert.That(ServiceStatus.AnyUnknown(withUnknown), Is.True);
            Assert.That(ServiceStatus.AnyUnknown(withoutUnknown), Is.False);
            Assert.That(ServiceStatus.AnyUnknown(new int[0]), Is.False);
            Assert.That(ServiceStatus.AnyUnknown(null), Is.False);
        }
    }
}
