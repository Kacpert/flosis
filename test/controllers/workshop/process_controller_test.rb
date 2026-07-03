require "test_helper"

class Workshop::ProcessControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true, pr_review_enabled: true, pr_poll_minutes: 5, pr_polled_at: 1.minute.ago)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
  end

  test "renders the PR tab with stats trio, feed rows, and polling chip" do
    PrReview.create!(
      workspace: @workspace, pr_number: 7, pr_title: "DEV-836 thing", pr_author: "octocat",
      pr_branch: "dev-836-thing", pr_url: "https://github.com/acme/widgets/pull/7",
      outcome: "comments", comment_count: 3, reviewed_at: 1.hour.ago, last_reviewed_sha: "abc", initial_done: true
    )
    PrReview.create!(
      workspace: @workspace, pr_number: 8, pr_title: "DEV-900 other thing", pr_author: "hubot",
      pr_branch: "dev-900-other", pr_url: "https://github.com/acme/widgets/pull/8",
      outcome: "looks_good", comment_count: 0, reviewed_at: 30.minutes.ago, last_reviewed_sha: "def", initial_done: true
    )

    get workshop_process_path

    assert_response :success
    assert_select ".clar-tab", /AI PR Reviews/
    assert_select ".clar-tab", /AI Estimate/
    assert_select ".clar-tab", /AI Alerts/

    # stats trio
    assert_select "body", /reviewed today/
    assert_select "body", /with comments/
    assert_select "body", /looks good/

    # feed rows
    assert_select "body", /#7/
    assert_select "body", /DEV-836 thing/
    assert_select "body", /octocat/
    assert_select ".clar-mono", /dev-836-thing/
    assert_select "body", /3 comments/
    assert_select "body", /Looks good!/
    assert_select "a[href=?]", "https://github.com/acme/widgets/pull/7", text: /GitHub/

    # polling chip
    assert_select "body", /Polling every 7 min/
    assert_select "body", /last .*ago/

    # disclaimer
    assert_select "body", /The AI never approves or merges/
  end

  test "empty state when pr_review_enabled is off" do
    @workspace.update!(pr_review_enabled: false)

    get workshop_process_path

    assert_response :success
    assert_select "body", /Configuration/
  end
end
