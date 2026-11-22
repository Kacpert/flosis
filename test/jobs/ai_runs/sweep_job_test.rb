require "test_helper"

class AiRuns::SweepJobTest < ActiveJob::TestCase
  def running(ran_at)
    AiRun.create!(workspace: workspaces(:one), area: "agents", automation: "Rule", status: "running", ran_at: ran_at,
                  input_tokens: 40)
  end

  test "sweeper fails stale running rows and leaves fresh ones" do
    stale = running(4.hours.ago)
    fresh = running(10.minutes.ago)

    AiRuns::SweepJob.perform_now

    stale.reload
    assert_equal "failed", stale.status
    assert_nil stale.cost_usd
    assert_nil stale.price_usd
    assert_equal 40, stale.input_tokens
    assert_equal "running", fresh.reload.status
  end
end
