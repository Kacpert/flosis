require "test_helper"
require "tmpdir"

# Five jobs used to chdir into one machine-wide checkout. Each of them is
# handed a project, and each project resolves its own directory — so a second
# client's code is never read out of the first client's tree.
class CodebasePathTest < ActiveSupport::TestCase
  JOBS = [ PrReviewJob, AlertRuleRunJob, BugAttributionJob, AutoEstimateJob,
           BackfillDeliveredEstimatesJob ].freeze

  setup do
    @project = projects(:jira_project)
    @workspace = @project.workspace
  end

  # The CLI must not even be constructed: chdir'ing into somebody else's tree
  # and answering from it is exactly the failure being prevented.
  def refusing_cli
    original = ClaudeCliService.method(:new)
    ClaudeCliService.define_singleton_method(:new) do |**kwargs|
      raise "the job ran Claude against #{kwargs[:codebase_path].inspect}"
    end
    yield
  ensure
    ClaudeCliService.define_singleton_method(:new, original)
  end

  test "no job carries its own machine-wide codebase constant any more" do
    (JOBS + [ ProjectFeaturesScanJob ]).each do |job|
      assert_not job.const_defined?(:CODEBASE_PATH, false),
                 "#{job} still defines CODEBASE_PATH"
    end
  end

  test "a project resolves its own checkout" do
    @project.update_columns(workspace_dir: "/tmp/clients/9/9", github_repo: "acme/partner-portal")

    assert_equal "/tmp/clients/9/9/partner-portal", @project.repo_checkout_path
  end

  # repo_checkout_path is also the clone TARGET (ProjectRepoCheckoutJob), so it
  # still answers for a directory that does not exist yet. ai_codebase_path is
  # the question the AI jobs ask, and it only answers for a tree that is
  # genuinely this project's.
  test "a project with no folder of its own has no AI codebase" do
    @project.update_columns(workspace_dir: nil)

    assert_equal Project::ELVIUM_LEGACY_DIR, @project.repo_checkout_path
    assert_nil @project.ai_codebase_path
  end

  test "a checkout that was never cloned is not an AI codebase" do
    @project.update_columns(workspace_dir: "/tmp/clients/does-not-exist", github_repo: "acme/partner-portal")

    assert_nil @project.ai_codebase_path
  end

  test "a cloned checkout is the project's own AI codebase" do
    Dir.mktmpdir do |dir|
      @project.update_columns(workspace_dir: dir, github_repo: "acme/partner-portal")
      FileUtils.mkdir_p(@project.repo_checkout_path)

      assert_equal @project.repo_checkout_path, @project.ai_codebase_path
    end
  end

  test "the grandfathered elvium checkout stays entitled to itself" do
    @project.update_columns(workspace_dir: Project::ELVIUM_LEGACY_DIR)

    assert_equal Project::ELVIUM_LEGACY_DIR, @project.ai_codebase_path
  end

  # ---- the jobs skip rather than answer about the wrong codebase ----------

  test "PrReviewJob does not review against another project's tree" do
    @project.update_columns(workspace_dir: nil)
    pr = { "number" => 7, "title" => "t", "head" => { "ref" => "b", "sha" => "abc" }, "body" => "" }

    refusing_cli do
      assert_nil PrReviewJob.new.send(:ai_issues, @project, pr, [], "initial")
    end
  end

  test "AlertRuleRunJob does not run a rule against another project's tree" do
    @project.update_columns(workspace_dir: nil)
    webhook = DiscordWebhook.create!(workspace: @workspace, project: @project,
                                     channel_name: "#dev-alerts",
                                     url: "https://discord.com/api/webhooks/1/abc")
    rule = AlertRule.create!(workspace: @workspace, project: @project, discord_webhook: webhook,
                             name: "QA watch", prompt: "Notify when QA is backed up.",
                             frequency: "daily", run_at_time: "13:00")

    refusing_cli { assert_nil AlertRuleRunJob.new.send(:run_ai, rule) }
  end

  test "BugAttributionJob does not attribute a bug from another project's tree" do
    @project.update_columns(workspace_dir: nil)
    bug = { task: nil, title: "Export crashes", description: "", created_at: 3.days.ago }

    refusing_cli { assert_nil BugAttributionJob.new.send(:run_ai, @project, "ELV-777", bug) }
  end

  test "AutoEstimateJob does not estimate from another project's tree" do
    @project.update_columns(workspace_dir: nil)

    refusing_cli { assert_nil AutoEstimateJob.new.send(:run_ai, tasks(:jira_task)) }
  end

  test "BackfillDeliveredEstimatesJob does not estimate from another project's tree" do
    @project.update_columns(workspace_dir: nil)
    delivered = @project.delivered_issues.create!(jira_key: "ELV-900", title: "Old work")

    refusing_cli { assert_nil BackfillDeliveredEstimatesJob.new.send(:estimate, delivered, @project) }
  end

  test "ProjectFeaturesScanJob does not summarise another project's codebase" do
    @project.update_columns(workspace_dir: nil)

    refusing_cli { assert_not ProjectFeaturesScanJob.new.send(:scan_and_store, @project) }
    assert_nil @project.reload.features_summary_updated_at
  end
end
