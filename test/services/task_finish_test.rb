require "test_helper"

# Finish (Kacper, 2026-11-21, answer (a)): Jira first, then the task's branch,
# then Ready, wherever the project has Jira or GitHub.
class TaskFinishTest < ActiveSupport::TestCase
  # The machine's own Jira login stands in for a project's (ProjectCredentials);
  # these tests decide for themselves whether the project has Jira.
  setup do
    @machine_jira = %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].to_h { |name| [ name, ENV.delete(name) ] }
    @project = projects(:jira_project)
    @project.update!(jira_site: "acme.atlassian.net", jira_email: "j@acme.test", jira_api_token: "jt",
                     github_repo: "acme/app", github_token: "tok")
    @task = @project.tasks.create!(name: "SCRUM-70 Add token calculations", external_reference: "SCRUM-70", external_type: "jira",
                                   in_pipeline: true, workshop_stage: "details")
    @task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "ai", version: 5, content: "Text.").make_current!
    @calls = []
  end

  teardown do
    @machine_jira.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def writer(result = { ok: true, key: "SCRUM-70" }, &on_commit)
    calls = @calls
    Object.new.tap do |fake|
      fake.define_singleton_method(:commit_detail) { |draft| calls << :jira; on_commit&.call(draft); result }
      fake.define_singleton_method(:commit_brief) { |_brief| calls << :jira; result }
    end
  end

  def branch(result = { ok: true, branch: "feat/scrum-70-add-token-calculations", sha: "c1", error: nil })
    calls = @calls
    lambda do |task|
      @branch_task = task
      Object.new.tap { |fake| fake.define_singleton_method(:push!) { calls << :branch; result } }
    end
  end

  test "Jira first, then the branch, then Ready" do
    result = TaskFinish.new(@task, writer: writer, branch: branch).run!

    assert result[:ok]
    assert_equal [ :jira, :branch ], @calls
    assert @task.reload.stage_ready?
    assert_nil @task.detail_saved_locally_at
    assert_equal "Jira updated · branch feat/scrum-70-add-token-calculations created", result[:toast]
  end

  test "a Jira failure stops everything" do
    result = TaskFinish.new(@task, writer: writer({ ok: false, error: "403 Forbidden" }), branch: branch).run!

    assert_equal [ false, "Couldn't write to Jira: 403 Forbidden" ], result.values_at(:ok, :error)
    assert_equal [ :jira ], @calls
    assert @task.reload.stage_details?
  end

  test "a branch failure still reaches Ready, and says so" do
    failed = { ok: false, branch: "feat/x", sha: nil, error: "The project's GitHub token can't write to acme/app (403)." }
    result = TaskFinish.new(@task, writer: writer, branch: branch(failed)).run!

    assert result[:ok]
    assert @task.reload.stage_ready?
    assert_equal "Jira updated · the branch couldn't be created", result[:toast]
  end

  test "a task without a ticket gets one, and its branch is named by the new key" do
    @task.update!(external_reference: nil, external_type: nil)
    created = writer({ ok: true, key: "SCRUM-71" }) { |draft| draft.task.update!(external_reference: "SCRUM-71", external_type: "jira") }

    result = TaskFinish.new(@task, writer: created, branch: branch).run!

    assert_equal "SCRUM-71", @branch_task.external_reference
    assert_equal "Jira ticket created · SCRUM-71 · branch feat/scrum-70-add-token-calculations created", result[:toast]
  end

  test "a project with only GitHub skips Jira, and one with neither finishes locally as today" do
    @project.update!(jira_site: nil)
    assert TaskFinish.new(@task, writer: writer, branch: branch).run![:ok]
    assert_equal [ :branch ], @calls

    @calls.clear
    @task.update!(workshop_stage: "details")
    @project.update!(github_repo: nil)
    result = TaskFinish.new(@task.reload, writer: writer, branch: branch).run!
    assert result[:ok]
    assert_equal [], @calls
    assert @task.reload.stage_ready?
    assert @task.detail_saved_locally_at
  end
  # Review C1: the server's own Jira login (.env) makes every project look
  # configured; only a project linked to Jira writes there.
  test "with the server's Jira login set, a project not linked to Jira still finishes locally" do
    ENV["JIRA_DOMAIN"] = "server.atlassian.net"
    ENV["JIRA_EMAIL"] = "bot@server.test"
    ENV["JIRA_API_TOKEN"] = "server-token"
    project = projects(:plain_project)
    project.update!(github_repo: nil)
    task = project.tasks.create!(name: "Local idea", in_pipeline: true, workshop_stage: "details")

    result = TaskFinish.new(task, writer: writer, branch: branch).run!
    assert result[:ok]
    assert_equal [], @calls
    assert task.reload.stage_ready?
    assert_equal [ false, false ], TaskFinish.integrations(project)
    assert_equal [ true, true ], TaskFinish.integrations(@project)
  end
end
