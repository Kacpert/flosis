require "test_helper"

# SCRUM-70: what each AI area cost the organization in a chosen month, at the
# right end of the area's page title — for someone who turned costs on.
class Workshop::AiAreaCostsTest < ActionDispatch::IntegrationTest
  include AiRunTestHelper

  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  def run!(area:, price:, project: @project, own_key: false, ran_at: Time.current)
    AiRun.create!(workspace: workspaces(:one), project: project, area: area, automation: "Test", status: "succeeded",
                  ran_at: ran_at, own_key: own_key, cost_usd: price, price_usd: price)
  end

  def area_figure
    css_select("[data-area-cost]").first
  end

  test "the PR tab shows the organization's PR reviews this month" do
    run!(area: "pr_reviews", price: 100)
    run!(area: "pr_reviews", price: 54.90, project: projects(:plain_project))
    run!(area: "estimates", price: 7)
    show_ai_costs!

    get workshop_process_path(tab: "pr")
    figure = area_figure
    assert figure, "the PR tab carries its area's figure"
    assert_includes figure.text.squish, "PR reviews"
    assert_includes figure.text.squish, "$154.90"
    assert_includes figure.text.squish, "2 runs"
  end

  test "each tab and page names its own area" do
    show_ai_costs!
    { workshop_process_path(tab: "estimate") => "AI estimates", workshop_process_path(tab: "alerts") => "Agents and alerts",
      workshop_bugs_path => "Bug analysis", workshop_pipeline_path => "Task conversations" }.each do |path, area|
      get path
      assert_includes area_figure&.text.to_s, area, path
    end
  end

  test "the area figure leaves out own key runs" do
    run!(area: "pr_reviews", price: 10)
    run!(area: "pr_reviews", price: 99, own_key: true)
    show_ai_costs!

    get workshop_process_path(tab: "pr")
    assert_includes area_figure.text, "$10.00"
    refute_includes area_figure.text, "$109.00"
  end

  test "no area figure while costs are off" do
    run!(area: "pr_reviews", price: 10)
    get workshop_process_path(tab: "pr")
    assert_nil area_figure
  end

  test "the month picker lists last month when it had runs" do
    run!(area: "pr_reviews", price: 268.40, ran_at: 1.month.ago)
    show_ai_costs!

    get workshop_process_path(tab: "pr")
    last_month = 1.month.ago.to_date
    option = css_select("[data-area-cost] option").find { |o| o.text.include?(last_month.strftime("%B %Y")) }
    assert option, "last month is offered"
    assert_equal "268.40|1", option["value"]
  end

  # Final review I3: an area month none of whose runs reported a cost.
  test "an area month whose runs all reported no cost reads unknown, not $0.00" do
    run!(area: "pr_reviews", price: nil)
    show_ai_costs!
    get workshop_process_path(tab: "pr")
    assert_includes area_figure.text, "unknown"
    refute_includes area_figure.text, "$0.00"
  end

end
