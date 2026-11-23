require "test_helper"

# SCRUM-70: what each item cost in AI, on the line that already carries it —
# only for someone who turned costs on, in an organization that shows them.
class Workshop::AiItemCostsTest < ActionDispatch::IntegrationTest
  include AiRunTestHelper

  FIGURE = "$12.40 ($3.23 this month)".freeze

  setup do
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  def pipeline_task
    tasks(:jira_task).tap { |task| task.update!(in_pipeline: true, workshop_stage: "briefing") }
  end

  test "the task chat shows the task conversation's AI cost when costs are on" do
    task = pipeline_task
    priced_runs!(task, area: "task_conversations", total: 12.40, this_month: 3.23)
    priced_runs!(task, area: "estimates", total: 99, this_month: 99)
    show_ai_costs!

    get workshop_idea_path(task, stage: "briefing")
    assert_response :success
    assert_includes response.body, FIGURE
    refute_includes response.body, "$99.00"
  end

  test "the task chat shows no AI cost when the person has not turned costs on" do
    task = pipeline_task
    priced_runs!(task, area: "task_conversations", total: 12.40, this_month: 3.23)

    get workshop_idea_path(task, stage: "briefing")
    refute_includes response.body, FIGURE
  end

  test "the task chat shows no AI cost while the organization hides costs" do
    task = pipeline_task
    priced_runs!(task, area: "task_conversations", total: 12.40, this_month: 3.23)
    show_ai_costs!
    workspaces(:one).update!(ai_costs_enabled: false)

    get workshop_idea_path(task, stage: "briefing")
    refute_includes response.body, FIGURE
  end

  test "the PR tab shows each review's AI cost" do
    @project.update!(github_token: "t", github_repo: "acme/widgets", pr_review_enabled: true)
    review = PrReview.create!(workspace: workspaces(:one), project: @project, pr_number: 19, pr_title: "Designs: count features",
                              pr_author: "kacper", pr_branch: "feat/x", reviewed_at: Time.current, outcome: "comments")
    priced_runs!(review, area: "pr_reviews", total: 12.40, this_month: 3.23)
    show_ai_costs!

    get workshop_process_path(tab: "pr")
    assert_includes response.body, FIGURE
    # Kacper, 2026-11-23 ("co to w ogóle jest?"): the figure says it is AI.
    assert_select "[data-ai-cost]", text: /\A· AI #{Regexp.escape(FIGURE)}\z/
  end

  test "the estimate tab shows each estimate's AI cost" do
    task = tasks(:jira_task)
    task.update!(ai_estimate_points: 5, ai_estimated_at: Time.current)
    priced_runs!(task, area: "estimates", total: 12.40, this_month: 3.23)
    show_ai_costs!

    get workshop_process_path(tab: "estimate")
    assert_includes response.body, FIGURE
  end

  test "a failed bug analysis still shows what it spent" do
    @project.tasks.create!(name: "ELV-777 Export crashes", external_type: "jira", external_reference: "ELV-777",
                           issue_type: "Bug", jira_created_at: 2.days.ago)
    bug = BugAttribution.create!(project: @project, jira_key: "ELV-777", status: "failed")
    priced_runs!(bug, area: "bug_analysis", total: 0.74, this_month: 0)
    show_ai_costs!

    get workshop_bugs_path
    assert_includes response.body, "$0.74 (none this month)"
  end

  test "Ready shows the task conversation's AI cost under the title" do
    task = pipeline_task
    task.update!(workshop_stage: "ready")
    priced_runs!(task, area: "task_conversations", total: 12.40, this_month: 3.23)
    show_ai_costs!

    get workshop_idea_path(task, stage: "ready")
    assert_response :success
    assert_includes response.body, FIGURE
    # Kacper, 2026-11-23: "skąd tu się wzięła cena $1.26 - co to w ogóle jest?"
    assert_select "[data-ai-cost]", text: /\AAI cost #{Regexp.escape(FIGURE)}\z/
  end

end
