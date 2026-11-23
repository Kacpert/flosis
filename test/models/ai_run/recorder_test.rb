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

  # Kacper (2026-11-23): a thread's big design turn was counted again with
  # every later message, because a resumed Claude session reports the whole
  # session so far. A run of a resumed session records what it added.
  GROWN = CLI_RESULT.merge("total_cost_usd" => 0.8, "modelUsage" => {
    "claude-opus-5[1m]" => { "inputTokens" => 14, "outputTokens" => 160, "cacheReadInputTokens" => 1600, "cacheCreationInputTokens" => 700, "costUSD" => 0.75 },
    "claude-haiku-5-5" => { "inputTokens" => 5, "outputTokens" => 20, "cacheReadInputTokens" => 0, "cacheCreationInputTokens" => 0, "costUSD" => 0.05 }
  }).freeze

  test "a run that resumes a session records only what it added to the session's report" do
    first = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(first, cli_usage, status: "succeeded", duration_ms: 1)
    later = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(later, cli_usage(GROWN), status: "succeeded", duration_ms: 1)

    later.reload
    assert_equal [ 4, 60, 600, 200 ], [ later.input_tokens, later.output_tokens, later.cache_read_tokens, later.cache_write_tokens ]
    assert_equal BigDecimal("0.3"), later.cost_usd
    assert_equal BigDecimal("0.39"), later.price_usd
    assert_equal BigDecimal("0.8"), later.model_usage.values.sum { |used| BigDecimal(used["costUSD"].to_s) }, "the CLI's report is kept as it came"
    assert_equal BigDecimal("0.5"), first.reload.cost_usd
  end

  test "a report no larger than what the run itself streamed is the run's own, even when it grew" do
    first = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(first, cli_usage, status: "succeeded", duration_ms: 1)
    later = AiRun::Recorder.start!(ai_attribution, own_key: false)
    usage = AiRun::Usage.new
    usage.see("type" => "assistant", "message" => { "id" => "m1", "model" => "claude-opus-5", "usage" => { "input_tokens" => 19, "output_tokens" => 180 } })
    usage.see(GROWN)
    AiRun::Recorder.finish!(later, usage, status: "succeeded", duration_ms: 1)
    assert_equal [ BigDecimal("0.8"), 180 ], [ later.reload.cost_usd, later.output_tokens ]
  end

  test "a session's report that did not grow is the run's own" do
    first = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(first, cli_usage(GROWN), status: "succeeded", duration_ms: 1)
    later = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(later, cli_usage, status: "succeeded", duration_ms: 1)
    assert_equal [ BigDecimal("0.5"), 120 ], [ later.reload.cost_usd, later.output_tokens ]
  end

  # The runs recorded before the fix, each carrying its session's whole report.
  test "recounting gives each run of a session its own share, priced with its own margin" do
    reports = [ CLI_RESULT, GROWN ]
    runs = reports.each_with_index.map do |report, i|
      run = AiRun::Recorder.start!(ai_attribution, own_key: false)
      AiRun::Recorder.finish!(run, cli_usage(report.merge("session_id" => "other-#{i}")), status: "succeeded", duration_ms: 1)
      run.update_columns(claude_session_id: "resumed", margin_percent: [ 30, 50 ][i])
      run
    end
    alone = AiRun::Recorder.start!(ai_attribution, own_key: false)
    AiRun::Recorder.finish!(alone, cli_usage(GROWN.merge("session_id" => "alone")), status: "succeeded", duration_ms: 1)

    assert_equal 1, AiRun::Recorder.recount_sessions!
    assert_equal [ BigDecimal("0.5"), BigDecimal("0.3") ], runs.map { |run| run.reload.cost_usd }
    assert_equal [ 120, 60 ], runs.map(&:output_tokens)
    assert_equal BigDecimal("0.45"), runs.last.price_usd
    assert_equal BigDecimal("0.8"), alone.reload.cost_usd
    assert_equal 0, AiRun::Recorder.recount_sessions!, "a second recount changes nothing"
  end

  # The CLI reports costs to more places than the columns keep.
  test "a recount of costs finer than a cent's millionth changes nothing the second time" do
    reports = [ CLI_RESULT, GROWN.merge("modelUsage" => GROWN["modelUsage"].transform_values { |used| used.merge("costUSD" => used["costUSD"] + 0.0000001234) }) ]
    reports.each_with_index do |report, i|
      run = AiRun::Recorder.start!(ai_attribution, own_key: false)
      AiRun::Recorder.finish!(run, cli_usage(report.merge("session_id" => "fine-#{i}")), status: "succeeded", duration_ms: 1)
      run.update_columns(claude_session_id: "fine")
    end
    assert_equal 1, AiRun::Recorder.recount_sessions!
    assert_equal 0, AiRun::Recorder.recount_sessions!
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
