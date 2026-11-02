require "test_helper"

class RateChangeTest < ActiveSupport::TestCase
  test "belongs to project_membership" do
    rc = rate_changes(:one_elvium_initial)
    assert_equal project_memberships(:one_elvium), rc.project_membership
  end

  test "tracks who changed the rate" do
    rc = rate_changes(:one_elvium_initial)
    assert_equal users(:one), rc.changed_by
  end

  test "initial rate has nil previous_rate_cents" do
    rc = rate_changes(:one_elvium_initial)
    assert_nil rc.previous_rate_cents
  end
end
