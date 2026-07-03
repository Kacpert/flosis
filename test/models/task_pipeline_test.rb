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
end
