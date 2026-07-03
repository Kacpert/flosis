require "test_helper"

class TaskPipelineTest < ActiveSupport::TestCase
  test "pipeline scope returns only in_pipeline tasks ordered by newest activity" do
    t = tasks(:jira_task) # fixtures are :jira_task, :local_task, :secret_task — there is no tasks(:one)
    t.update!(in_pipeline: true, workshop_stage: "briefing")
    assert_includes Task.pipeline, t
    refute_includes Task.pipeline, tasks(:local_task)
  end

  test "workshop_stage only accepts pipeline stages" do
    t = tasks(:jira_task)
    assert_raises(ArgumentError) { t.workshop_stage = "bogus" }
  end

  test "stage_rank orders new < briefing < details < ready" do
    assert Task::WORKSHOP_STAGES.index("new") < Task::WORKSHOP_STAGES.index("ready")
  end

  test "suggested_branch prefixes the Jira key (downcased) and a slug of the name" do
    t = tasks(:jira_task) # name: "ELV-1 Existing task", external_reference: "ELV-1"
    assert_equal "feat/elv-1-elv-1-existing-task", t.suggested_branch
  end

  test "suggested_branch omits the key for a local (non-Jira) task" do
    t = tasks(:local_task) # name: "Daily standup", no external_reference
    assert_equal "feat/daily-standup", t.suggested_branch
  end

  test "suggested_branch truncates a long slug to 32 chars and strips a trailing dash" do
    t = tasks(:local_task)
    t.name = "A very very very long idea name that goes on and on and on"
    assert_equal "feat/a-very-very-very-long-idea-name", t.suggested_branch
  end
end
