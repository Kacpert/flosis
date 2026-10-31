require "test_helper"

class DesignSetupTest < ActiveSupport::TestCase
  setup { @setup = DesignSetup.create!(project: projects(:jira_project), started_by: users(:one)) }

  test "the phases come in order, and there is none after the designs" do
    assert_equal "design_system", @setup.phase
    assert_equal "components", @setup.next_phase!
    assert_equal "designs", @setup.next_phase!
    assert_nil @setup.next_phase!
    assert_equal "designs", @setup.reload.phase
  end

  # Ruling P5-R2: a crawl that failed or was killed must not hold turns.
  test "a crawl counts as running only while asked for, not finished, not failed and not past its time" do
    assert_not @setup.crawling?
    @setup.update!(crawl_requested_at: Time.current)
    assert @setup.crawling?
    @setup.update!(crawl_error: "Login failed")
    assert_not @setup.crawling?
    @setup.update!(crawl_error: nil, crawled_at: Time.current)
    assert_not @setup.crawling?
    @setup.update!(crawled_at: nil, crawl_requested_at: 26.minutes.ago)
    assert_not @setup.crawling?
  end

  test "active setups" do
    @setup.update!(status: "approved")
    assert_not_includes DesignSetup.active, @setup
  end
end
