require "test_helper"

# SCRUM-71: a paused organization starts no new AI run; a project's own key
# still runs, and a run is funded from the plan or the top-up balance.
class ClaudeCliServicePausedTest < ActiveSupport::TestCase
  include AiRunTestHelper
  include FakeClaudeBinTestHelper

  setup do
    @workspace = workspaces(:one)
    billing_ready!(@workspace)
    @team = billing_plan(price: 300, margin: 50)
    travel_to Time.zone.local(2026, 12, 1, 6)
    Billing::Plans.new(@workspace.reload).choose!(@team)
  end

  def service(**options)
    ClaudeCliService.new(codebase_path: Dir.tmpdir, attribution: ai_attribution(workspace: @workspace), **options)
  end

  def spend!(price, funding: "plan")
    AiRun.create!(workspace: @workspace, area: "agents", automation: "Test", status: "succeeded", cost_usd: price,
                  price_usd: price, ran_at: Time.current, funding: funding)
  end

  def answer = %(STDIN.read; puts #{CLI_RESULT.to_json.inspect})

  test "at the limit with no balance a new run is refused and nothing is recorded" do
    spend!(BigDecimal("300"))
    assert Billing::Allowance.for(@workspace).paused?
    assert_equal :limit, Billing::Allowance.for(@workspace).reason
    with_fake_claude_bin(answer) do
      assert_no_difference "AiRun.count" do
        error = assert_raises(ClaudeCliService::PausedError) { service.start_session(prompt: "hi") }
        assert_equal "AI paused: limit reached.", error.message
      end
    end
  end

  test "a run on the project's own key is never refused" do
    spend!(BigDecimal("300"))
    project = projects(:jira_project)
    project.update_columns(workspace_id: @workspace.id, anthropic_api_key: "sk-ant-own")
    attribution = ai_attribution(workspace: @workspace, project: project)
    with_fake_claude_bin(answer) do
      ClaudeCliService.new(codebase_path: Dir.tmpdir, attribution: attribution, api_key: "sk-ant-own").start_session(prompt: "hi")
    end
    assert AiRun.last.own_key
    assert_nil AiRun.last.funding
  end

  test "under the limit a run is funded by the plan at the plan's margin" do
    with_fake_claude_bin(answer) { service.start_session(prompt: "hi") }
    run = AiRun.last
    assert_equal "plan", run.funding
    assert_equal BigDecimal("0.75"), run.price_usd
  end

  test "past the limit a top-up pays, at cost + 30%" do
    Billing::TopUps.new(@workspace).buy!(200)
    spend!(BigDecimal("300"))
    assert_not Billing::Allowance.for(@workspace).paused?
    with_fake_claude_bin(answer) { service.start_session(prompt: "hi") }
    run = AiRun.last
    assert_equal "top_up", run.funding
    assert_equal BigDecimal("0.65"), run.price_usd
    assert_equal BigDecimal("30"), run.margin_percent
    assert_equal BigDecimal("199.35"), Billing::Ledger.balance(@workspace)
  end

  test "a failing payment allows 15% of the plan price, then pauses; after 7 days it stays paused" do
    @billing_gateway.fail_next!
    travel_to Time.zone.local(2027, 1, 1, 6)
    Billing::MonthStartJob.perform_now
    allowance = Billing::Allowance.for(@workspace)
    assert allowance.payment_failing?
    assert_not allowance.paused?
    assert_equal BigDecimal("45"), allowance.grace_usd
    spend!(BigDecimal("45"))
    assert_equal :retry_spent, Billing::Allowance.for(@workspace).reason
    AiRun.where(workspace: @workspace).delete_all
    travel_to Time.zone.local(2027, 1, 8, 9)
    assert_equal :unpaid, Billing::Allowance.for(@workspace).reason
  end

  test "no plan: AI is paused, unless Flosis turned on free AI for the organization" do
    @workspace.billing.update!(plan_state: "ended")
    @workspace.update!(free_ai: false)
    assert_equal :no_plan, Billing::Allowance.for(@workspace).reason
    with_fake_claude_bin(answer) do
      error = assert_raises(ClaudeCliService::PausedError) { service.start_session(prompt: "hi") }
      assert_equal "AI paused: no plan.", error.message
    end
    @workspace.update!(free_ai: true)
    spend!(BigDecimal("1000"))
    assert_not Billing::Allowance.for(@workspace).paused?
    with_fake_claude_bin(answer) { service.start_session(prompt: "hi") }
    assert_equal "free", AiRun.last.funding
  end

  test "a plan chosen but not activated yet pauses AI too, without free AI" do
    @workspace.billing.update!(plan_state: "pending")
    @workspace.update!(free_ai: false)
    assert_equal :no_plan, Billing::Allowance.for(@workspace).reason
  end

  test "an unknown-cost run counts nowhere" do
    with_fake_claude_bin(%(STDIN.read)) do
      assert_raises(ClaudeCliService::ClaudeCliError) { service.start_session(prompt: "hi") }
    end
    assert_nil AiRun.last.funding
    assert_equal BigDecimal("0"), Billing::Ledger.plan_spend(@workspace)
  end
end
