require "test_helper"

# What Finish says it will do, and what the accepted-designs modal says is
# left (Kacper, 2026-11-21): by what the project has and what the task has.
class Workshop::FinishHelperTest < ActionView::TestCase
  include Workshop::FinishHelper

  # The machine's own Jira login stands in for a project's (ProjectCredentials);
  # these tests decide for themselves whether the project has Jira.
  setup do
    @machine_jira = %w[JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN].to_h { |name| [ name, ENV.delete(name) ] }
    @project = projects(:jira_project)
    @project.update!(jira_site: "acme.atlassian.net", jira_email: "j@acme.test", jira_api_token: "jt",
                     github_repo: "acme/app", github_token: "tok")
    @task = @project.tasks.create!(name: "SCRUM-70 Add token calculations", external_reference: "SCRUM-70", external_type: "jira")
  end

  teardown do
    @machine_jira.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  test "the label names what Finish will do" do
    assert_equal "Finish · Update Jira & Create branch", finish_label(@task)
    @task.update!(code_branch: "feat/x", code_branch_pushed_at: Time.current)
    assert_equal "Finish · Update Jira & branch", finish_label(@task)

    local = @project.tasks.create!(name: "Local idea")
    assert_equal "Finish · Create Jira ticket & branch", finish_label(local)

    @project.update!(github_repo: nil)
    assert_equal "Finish · Update Jira", finish_label(@task.reload)
    assert_equal "Finish · Create Jira ticket", finish_label(local.reload)

    @project.update!(jira_site: nil, github_repo: "acme/app")
    assert_equal "Finish · Create branch", finish_label(local.reload)

    @project.update!(github_repo: nil)
    assert_equal "Finish · go to Ready", finish_label(local.reload)
    assert finish_locally?(local)
  end

  test "what is left says what Finish will do" do
    assert_equal "A branch with the task for the developer to take over, and the Jira ticket updated with the new description.",
                 finish_whats_left(@task)
    local = @project.tasks.create!(name: "Local idea")
    assert_equal "A branch with the task for the developer to take over, and a Jira ticket created with the new description.",
                 finish_whats_left(local)
    assert_equal "feat/scrum-70-add-token-calculations · tasks/SCRUM-70/scrum-70.md", finish_target(@task)

    @project.update!(github_repo: nil)
    assert_equal "The Jira ticket updated with the new description.", finish_whats_left(@task.reload)
    assert_nil finish_target(@task)
  end
end
