require "test_helper"

# Bug Reporting (Task 8.2): stats + trend + bug analysis list (merged open
# tasks Bugs + delivered_issues Bugs, joined to bug_attributions by
# jira_key). See app/services/workshop_report.rb#bug_stats and
# .superpowers/sdd/task-8.2-brief.md.
class Workshop::BugsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  test "renders Bug Reporting with H1, stat cards, and the bug analysis list" do
    @project.tasks.create!(name: "Open bug", issue_type: "Bug", jira_created_at: Time.current,
      external_type: "jira", external_reference: "ELV-950")
    BugAttribution.create!(project: @project, jira_key: "ELV-950", origin_kind: "new_functionality",
      author_name: "Kacper", author_email: users(:one).email_address, confidence: "high",
      reasoning: "Introduced in commit abc123 which added the export path.", status: "done")

    get workshop_bugs_path

    assert_response :success
    assert_select "h1", "Bug Reporting"
    assert_select "body", /Bugs created/
    assert_select "body", /Created the most/
    assert_select "body", /Fixed the most/
    assert_select "body", /Bugs over time/
    assert_select "body", /Bug analysis/
    assert_select "body", /ELV-950/
    assert_select "body", /New functionality/
    assert_select "body", /Introduced in commit abc123/
  end

  test "origin badge shows Existing code for existing_code attributions" do
    @project.tasks.create!(name: "Old bug", issue_type: "Bug", jira_created_at: Time.current,
      external_type: "jira", external_reference: "ELV-951")
    BugAttribution.create!(project: @project, jira_key: "ELV-951", origin_kind: "existing_code",
      author_name: "Priya", confidence: "medium", reasoning: "Long-standing code.", status: "done")

    get workshop_bugs_path

    assert_response :success
    assert_select "body", /Existing code/
  end

  test "low confidence attribution prefixes the author with Likely:" do
    @project.tasks.create!(name: "Uncertain bug", issue_type: "Bug", jira_created_at: Time.current,
      external_type: "jira", external_reference: "ELV-952")
    BugAttribution.create!(project: @project, jira_key: "ELV-952", origin_kind: "existing_code",
      author_name: "Sam", confidence: "low", reasoning: "Weak signal.", status: "done")

    get workshop_bugs_path

    assert_response :success
    assert_select "body", /Likely: Sam/
  end

  test "pending attribution shows an Analyzing chip" do
    @project.tasks.create!(name: "Pending bug", issue_type: "Bug", jira_created_at: Time.current,
      external_type: "jira", external_reference: "ELV-953")
    BugAttribution.create!(project: @project, jira_key: "ELV-953", status: "pending")

    get workshop_bugs_path

    assert_response :success
    assert_select "body", /Analyzing/
  end

  test "failed attribution shows an Analyze retry button" do
    @project.tasks.create!(name: "Failed bug", issue_type: "Bug", jira_created_at: Time.current,
      external_type: "jira", external_reference: "ELV-954")
    BugAttribution.create!(project: @project, jira_key: "ELV-954", status: "failed")

    get workshop_bugs_path

    assert_response :success
    assert_select "form[action=?]", workshop_analyze_bug_path("ELV-954")
  end

  test "bug analysis list merges open tasks Bugs and delivered_issues Bugs by recency" do
    @project.tasks.create!(name: "Open one", issue_type: "Bug", jira_created_at: 1.day.ago,
      external_type: "jira", external_reference: "ELV-960")
    @project.delivered_issues.create!(jira_key: "ELV-961", title: "Fixed one", issue_type: "Bug",
      resolved_at: Time.current, jira_created_at: 2.days.ago)

    get workshop_bugs_path

    assert_response :success
    assert_select "body", /ELV-960/
    assert_select "body", /ELV-961/
  end

  test "POST analyze enqueues BugAttributionJob for a failed attribution" do
    attribution = BugAttribution.create!(project: @project, jira_key: "ELV-970", status: "failed")

    assert_enqueued_with(job: BugAttributionJob, args: [ @project.id, "ELV-970" ]) do
      post workshop_analyze_bug_path(attribution.jira_key)
    end

    assert_redirected_to workshop_bugs_path
  end

  test "POST analyze 404s for a bug attribution belonging to another project" do
    other_project = projects(:other_jira_project)
    BugAttribution.create!(project: other_project, jira_key: "SEC-970", status: "failed")

    post workshop_analyze_bug_path("SEC-970")

    assert_response :not_found
  end
end
