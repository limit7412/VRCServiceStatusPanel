require "../spec_helper"

private def history_of(*outcomes : Status::Outcome) : Status::History
  outcomes.reduce(Status::History.new) { |history, outcome| history.push(outcome) }
end

describe Status::Usecase do
  describe ".level_for_synthetic" do
    it "is operational when every recent check succeeded" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Success,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Operational
    end

    it "is degraded after a single failure" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Failure,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Degraded
    end

    it "is degraded when the latency threshold was exceeded" do
      history = history_of(
        Status::Outcome::Success,
        Status::Outcome::Success,
        Status::Outcome::Success,
      )

      Status::Usecase.level_for_synthetic(history, latency_exceeded: true)
        .should eq Status::Level::Degraded
    end

    it "is a major outage from the second failure" do
      history = history_of(
        Status::Outcome::Failure,
        Status::Outcome::Success,
        Status::Outcome::Failure,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::MajorOutage
    end

    it "is unknown when the latest response looked like bot detection" do
      history = history_of(
        Status::Outcome::Failure,
        Status::Outcome::Failure,
        Status::Outcome::Indeterminate,
      )

      Status::Usecase.level_for_synthetic(history).should eq Status::Level::Unknown
    end

    it "judges from the current run alone when no history was restored" do
      Status::Usecase.level_for_synthetic(Status::History.new)
        .should eq Status::Level::Operational

      Status::Usecase.level_for_synthetic(history_of(Status::Outcome::Failure))
        .should eq Status::Level::Degraded
    end
  end
end
