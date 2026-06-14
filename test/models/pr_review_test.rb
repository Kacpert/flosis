require "test_helper"

class PrReviewTest < ActiveSupport::TestCase
  test "valid with workspace and pr_number" do
    r = PrReview.new(workspace: workspaces(:one), pr_number: 7)
    assert r.valid?
  end

  test "pr_number unique per workspace" do
    PrReview.create!(workspace: workspaces(:one), pr_number: 7)
    dup = PrReview.new(workspace: workspaces(:one), pr_number: 7)
    assert_not dup.valid?
  end
end
