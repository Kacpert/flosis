require "test_helper"

# Claude's session and usage limits, as the CLI words them when a turn stops on
# one (Designs imports): whether a turn hit one, and when it resets.
class Designs::UsageLimitTest < ActiveSupport::TestCase
  WARSAW = ActiveSupport::TimeZone["Europe/Warsaw"]
  STOPPED = "Claude stopped with an error: You've hit your session limit · resets 8am (Europe/Warsaw)".freeze

  test "hit? matches the CLI's limit messages" do
    assert Designs::UsageLimit.hit?(STOPPED)
    assert Designs::UsageLimit.hit?("Claude AI usage limit reached|1762243200")
    refute Designs::UsageLimit.hit?("Failed to parse Claude response")
    refute Designs::UsageLimit.hit?(nil)
  end

  test "reads the reset hour in its zone, later today" do
    now = WARSAW.local(2026, 11, 3, 6, 50)
    assert_equal WARSAW.local(2026, 11, 3, 8, 0), Designs::UsageLimit.reset_at(STOPPED, now: now)
  end

  test "rolls to the next day once the hour has passed" do
    now = WARSAW.local(2026, 11, 3, 9, 0)
    assert_equal WARSAW.local(2026, 11, 4, 8, 0), Designs::UsageLimit.reset_at(STOPPED, now: now)
  end

  test "reads minutes and a date" do
    now = WARSAW.local(2026, 11, 3, 6, 50)
    text = "You've hit your weekly limit · resets Nov 5, 8:30pm (Europe/Warsaw)"
    assert_equal WARSAW.local(2026, 11, 5, 20, 30), Designs::UsageLimit.reset_at(text, now: now)
  end

  test "reads an epoch" do
    assert_equal Time.zone.at(1_762_243_200), Designs::UsageLimit.reset_at("Claude AI usage limit reached|1762243200", now: Time.current)
  end

  test "a limit whose reset cannot be read pauses thirty minutes" do
    now = WARSAW.local(2026, 11, 3, 6, 50)
    assert_equal now + 30.minutes, Designs::UsageLimit.reset_at("You've hit your session limit", now: now)
  end
end
