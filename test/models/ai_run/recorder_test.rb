require "test_helper"

class AiRun::RecorderTest < ActiveSupport::TestCase
  include AiRunTestHelper

  setup { @workspace = workspaces(:one) }

  test "finish prices a run with the plan's margin and freezes the month's limit" do
    @workspace.update!(ai_plan: ai_plans(:scale), ai_plan_assigned_at: Time.current)
    run = AiRun::Recorder.start!(ai_attribution, own_key: false)
    assert_equal "running", run.status
    assert_equal "Elvium", run.project_name

    AiRun::Recorder.finish!(run, cli_usage, status: "succeeded", duration_ms: 1200)
    run.reload
    assert_equal "succeeded", run.status
    assert_equal BigDecimal("30"), run.margin_percent
    assert_equal BigDecimal("0.65"), run.price_usd
    assert_equal 1200, run.duration_ms
    assert_equal "claude-opus-5", run.model
    assert_equal BigDecimal("1200"), AiMonthLimit.find_by!(workspace: @workspace, month: Date.current.beginning_of_month).limit_usd
  end

  test "no plan uses the default margin" do
    run = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(run, cli_usage, status: "succeeded", duration_ms: 1)
    assert_equal BigDecimal("30"), run.reload.margin_percent
    assert_equal BigDecimal("0.65"), run.price_usd
  end

  test "own key keeps no margin and its price is its cost" do
    @workspace.update!(ai_plan: ai_plans(:scale))
    run = AiRun::Recorder.start!(ai_attribution, own_key: true)
    AiRun::Recorder.finish!(run, cli_usage, status: "succeeded", duration_ms: 1)
    run.reload
    assert run.own_key
    assert_nil run.margin_percent
    assert_equal BigDecimal("0.5"), run.price_usd
  end

  test "unknown cost stays nil in both cost and price" do
    run = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(run, cli_usage(CLI_RESULT.except("total_cost_usd")), status: "failed", duration_ms: 1)
    run.reload
    assert_nil run.cost_usd
    assert_nil run.price_usd
    assert_equal 15, run.input_tokens
  end

  test "a model never seen is added to the price list" do
    run = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(run, cli_usage, status: "succeeded", duration_ms: 1)
    assert AiModel.exists?(model_id: "claude-opus-5")
  end

  test "progress saves tokens but not more often than every 30 seconds" do
    run = AiRun::Recorder.start!(ai_attribution, own_key: false)
    run.update_columns(updated_at: 1.minute.ago)
    AiRun::Recorder.progress!(run, cli_usage)
    assert_equal 15, run.reload.input_tokens
    assert_equal "running", run.status

    AiRun::Recorder.progress!(run, cli_usage(CLI_RESULT.merge("modelUsage" => { "m" => { "inputTokens" => 99 } })))
    assert_equal 15, run.reload.input_tokens
  end

  test "recording errors never raise" do
    with_failing(AiRun.singleton_class, :create!) do
      assert_nil AiRun::Recorder.start!(ai_attribution, own_key: false)
    end
    assert_nil AiRun::Recorder.finish!(nil, cli_usage, status: "failed", duration_ms: 1)
    run = AiRun::Recorder.start!(ai_attribution, own_key: false)
    run.define_singleton_method(:update!) { |*| raise ActiveRecord::StatementInvalid, "boom" }
    assert_nil AiRun::Recorder.finish!(run, cli_usage, status: "failed", duration_ms: 1)
  end

  private

  # The method raises for the block's length, as a database that refuses a
  # write would.
  def with_failing(owner, name)
    original = owner.instance_method(name)
    owner.define_method(name) { |*, **| raise ActiveRecord::StatementInvalid, "boom" }
    yield
  ensure
    owner.define_method(name, original)
  end
end
