require "test_helper"

class AiCostsHelperTest < ActionView::TestCase
  include AiCostsHelper

  attr_accessor :current_workspace, :current_user

  setup do
    self.current_workspace = workspaces(:one)
    self.current_user = users(:one)
  end

  test "costs show only when the organization allows and the person asked" do
    [ [ true, true, true ], [ true, false, false ], [ false, true, false ], [ false, false, false ] ].each do |org, person, shown|
      current_workspace.ai_costs_enabled = org
      current_user.show_ai_costs = person
      assert_equal shown, ai_costs_visible?, "organization #{org}, person #{person}"
    end
  end

  test "an item's figure is formatted when visible and nil when not" do
    task = tasks(:jira_task)
    figures = { [ "Task", task.id ] => AiCosts::Figure.new(total: BigDecimal("0.68"), this_month: BigDecimal("0.68"), priced_runs: 1, runs: 1) }
    current_user.show_ai_costs = true
    assert_equal "$0.68", ai_item_cost(figures, task)
    current_user.show_ai_costs = false
    assert_nil ai_item_cost(figures, task)
  end
end
