require "test_helper"

class Workshop::ProcessControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Inside PrReviewCheckJob's review hours: the polling chip reads the clock,
    # and a run after 20:00 would otherwise find it paused.
    travel_to Time.zone.local(2026, 11, 3, 10, 0)
    @workspace = workspaces(:one)
    @workspace.update!(workshop_enabled: true)
    @project = projects(:jira_project)
    @project.update!(pr_review_enabled: true, pr_polled_at: 1.minute.ago)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
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
    assert_select ".clar-tab", /AI Agents & Alerts/

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

  # The switch and the poll timestamp the poller actually writes are the
  # project's. Reading the workspace's showed the dashboard to every project in
  # a workspace whose flag was ever on, with "last never" forever — the
  # workspace no longer has one to read.
  test "the dashboard follows the project's switch" do
    @project.update!(pr_review_enabled: true, pr_polled_at: 3.minutes.ago)

    get workshop_process_path

    assert_response :success
    assert_select "body", /reviewed today/
    assert_select "body", /last 3 min ago/
  end

  test "empty state when the project's reviews are off" do
    @project.update!(pr_review_enabled: false)

    get workshop_process_path

    assert_response :success
    assert_select "body", /AI PR reviews are turned off/
    assert_select "body", /Configuration/
  end

  # The switch sits in Configuration's GitHub dialog, and the bare page opens
  # on a tab without it: four tabs clicked through and no sign of the switch.
  test "the way out of the off state opens the GitHub dialog that holds the switch" do
    @project.update!(pr_review_enabled: false)

    get workshop_process_path

    assert_select "a[href=?]", workshop_configuration_path(tab: "integrations", manage: "github"), text: /Go to Configuration/
  end

  # PrReviewCheckJob only polls 09:00–20:00. A chip promising a poll every
  # 7 minutes at night kept reviews switched on in the evening at "last never"
  # until morning, with nothing saying why.
  test "outside the review hours the chip says the poller is paused until morning" do
    travel_to Time.zone.local(2026, 11, 3, 23, 30)

    get workshop_process_path

    assert_response :success
    assert_select "body", /Paused until 09:00/
    assert_no_match(/Polling every/, response.body)
  end

  # The chip used to print the raw setting while PrReviewCheckJob floors the
  # interval, so a project set to 1 read "every 1 min" and was polled every 7.
  test "the polling chip prints the interval the poller will honour, not the raw setting" do
    @project.update!(pr_poll_minutes: 1)

    get workshop_process_path

    assert_response :success
    assert_select "body", /Polling every 7 min/
    assert_no_match(/Polling every 1 min/, response.body)
  end

  test "renders the AI Estimate tab with summary card and recently-estimated tasks" do
    project = tasks(:jira_task).project
    project.update!(estimation_trigger: "status", estimation_field_names: ["AI estimation", "Story point estimate"])

    task = tasks(:jira_task)
    task.update!(ai_estimate_points: 8, ai_estimated_at: 1.hour.ago, story_points: 5)

    get workshop_process_path(tab: "estimate")

    assert_response :success
    assert_select ".clar-tab.clar-tab-active", /AI Estimate/

    # summary card
    assert_select "body", Regexp.new(Regexp.escape(project.name))
    assert_select "body", /Status changes to/
    assert_select "body", /AI estimation/
    assert_select "body", /Story point estimate/
    assert_select "body", /Manual estimate fields are never touched/
    assert_select "body", /Configuration/

    # table
    assert_select "body", /TASK/
    assert_select "body", /TITLE/
    assert_select "body", /AI ESTIMATION/
    assert_select "body", /ACTION/
    assert_select "body", /estimated/ # "N tasks estimated" card header
    assert_select "body", Regexp.new(Regexp.escape(task.external_reference))
    assert_select "body", /8/
    # A per-row Re-estimate button (forces a fresh estimate).
    assert_select "form[action='#{estimate_workshop_idea_path(task)}'] button", text: /Re-estimate/
  end

  test "AI Estimate tab shows a search input and each row's estimated-at timestamp" do
    @project.update!(estimation_trigger: "manual")
    task = tasks(:jira_task)
    task.update!(ai_estimate_points: 3, ai_estimated_at: 1.hour.ago)

    get workshop_process_path(tab: "estimate")

    assert_response :success
    # Client-side search filter.
    assert_select "input[placeholder='Search tasks…'][data-clar-filter-target='query']"
    # Relative timestamp next to the title (e.g. "1h ago").
    assert_select "body", /ago/
  end

  test "renders the AI Alerts tab with rules list, new-rule modal, and history modal frame" do
    project = tasks(:jira_task).project
    post switch_workshop_project_path, params: { project_id: project.id }
    webhook = DiscordWebhook.create!(workspace: @workspace, channel_name: "#dev-alerts", url: "https://discord.com/api/webhooks/1/abc")
    rule = AlertRule.create!(
      workspace: @workspace, project: project, discord_webhook: webhook,
      name: "QA backlog watch", prompt: "If more than 4 tasks have been in QA for longer than 3 days, send a notification.",
      frequency: "daily", run_at_time: "13:00"
    )
    rule.alert_runs.create!(fired: true, summary: "2 tasks flagged", detail: "SP-1, SP-2", status: "ok", ran_at: 1.hour.ago)

    get workshop_process_path(tab: "alerts")

    assert_response :success
    assert_select ".clar-tab.clar-tab-active", /AI Agents & Alerts/
    assert_select "body", /QA backlog watch/
    assert_select "body", /Sent · 2 tasks flagged/
    assert_select "body", /Daily · 13:00/
    assert_select "body", /#dev-alerts · Discord/
    assert_select "body", /View history/
    assert_select "body", /New rule/
    assert_select "body", /A scheduled prompt\. On its schedule the AI inspects the live Jira board state/
    assert_select "body", /WHAT TO WATCH FOR/
    assert_select "turbo-frame##{dom_id_for_history(rule)}"

    # Regression: the new-rule form inputs must submit under alert_rule[<attr>],
    # NOT the double-nested alert_rule[alert_rule[<attr>]] that resulted from
    # passing a bracketed string to f.text_field on an alert_rule form builder.
    # The double-nesting made every create fail with "… can't be blank".
    assert_select "form input[name='alert_rule[name]']"
    assert_select "form textarea[name='alert_rule[prompt]']"
    assert_select "form input[name='alert_rule[run_at_time]']"
    # Schedule builder (replaced the old frequency <select>): mode, day set,
    # interval and window all post as plain alert_rule[<attr>] fields.
    assert_select "form input[name='alert_rule[schedule_mode]']"
    assert_select "form input[name='alert_rule[schedule_days]']"
    assert_select "form input[name='alert_rule[interval_hours]']"
    assert_select "form input[name='alert_rule[window_enabled]']"
    assert_select "form input[name='alert_rule[window_from]']"
    assert_select "form input[name='alert_rule[window_to]']"
    assert_select "form input[name='alert_rule[alert_rule[name]]']", false,
      "alert_rule form fields must not be double-nested"
  end

  test "a failed review shows why it failed and when it retries, instead of silently looping" do
    record = PrReview.create!(
      workspace: @workspace, pr_number: 9, pr_title: "DEV-958 deletion dates", pr_author: "octocat",
      pr_branch: "dev-958", pr_url: "https://github.com/acme/widgets/pull/9"
    )
    record.record_failure!("abc", "Claude CLI not found")

    get workshop_process_path

    assert_response :success
    assert_select "body", /Failed/
    assert_select "body", /Claude CLI not found/
    assert_select "body", /attempt 2 of #{PrReview::MAX_ATTEMPTS}/
  end

  test "a review that used up its retry budget says so rather than showing a next attempt" do
    record = PrReview.create!(workspace: @workspace, pr_number: 9, pr_title: "DEV-958 deletion dates",
                              pr_author: "octocat", pr_branch: "dev-958")
    PrReview::MAX_ATTEMPTS.times { record.record_failure!("abc", "Claude CLI not found") }

    get workshop_process_path

    assert_response :success
    assert_select "body", /gave up after #{PrReview::MAX_ATTEMPTS} tries/
    assert_select "body", /waiting for new commits/
  end

  test "the edit modal lists previous prompt versions, with the full text to restore" do
    project = tasks(:jira_task).project
    post switch_workshop_project_path, params: { project_id: project.id }
    rule = AlertRule.create!(workspace: @workspace, project: project, notify_enabled: false,
                             name: "Edited", prompt: "The original wording.",
                             frequency: "daily", run_at_time: "13:00")
    rule.update!(prompt: "The new wording.")

    get workshop_process_path(tab: "alerts")

    assert_response :success
    assert_select "summary", /Previous versions \(1\)/
    # The whole old prompt travels with the button, so restoring needs no request.
    assert_select "button.clar-prompt-version[data-prompt=?]", "The original wording."
    assert_select "textarea[data-clar-prompt-history-target=?]", "field"
  end

  test "a rule whose prompt was never edited shows no history section" do
    project = tasks(:jira_task).project
    post switch_workshop_project_path, params: { project_id: project.id }
    AlertRule.create!(workspace: @workspace, project: project, notify_enabled: false,
                      name: "Untouched", prompt: "Only ever this.",
                      frequency: "daily", run_at_time: "13:00")

    get workshop_process_path(tab: "alerts")

    assert_response :success
    assert_select "summary", { text: /Previous versions/, count: 0 }
  end

  test "the rules list is draggable and carries each rule's id" do
    project = tasks(:jira_task).project
    post switch_workshop_project_path, params: { project_id: project.id }
    rule = AlertRule.create!(workspace: @workspace, project: project, notify_enabled: false,
                             name: "Draggable", prompt: "Watch.", frequency: "daily", run_at_time: "13:00")

    get workshop_process_path(tab: "alerts")

    assert_response :success
    assert_select "[data-controller=?][data-clar-reorder-url-value=?]", "clar-reorder",
                  reorder_workshop_alert_rules_path
    assert_select "[data-clar-reorder-target='item'][data-rule-id=?]", rule.id.to_s
    assert_select "[data-clar-reorder-target='handle']"
    # The whole card is the grab area, not just the handle icon.
    assert_select "[data-clar-reorder-target='item'][data-action*=?]", "mousedown->clar-reorder#arm"
  end

  # A prompt runs to a dozen lines; unclamped it pushed each rule's schedule,
  # channel and actions below the fold.
  test "a rule's prompt is clamped with a toggle to open it" do
    project = tasks(:jira_task).project
    post switch_workshop_project_path, params: { project_id: project.id }
    AlertRule.create!(workspace: @workspace, project: project, notify_enabled: false,
                      name: "Long one", prompt: "Watch the board. " * 60,
                      frequency: "daily", run_at_time: "13:00")

    get workshop_process_path(tab: "alerts")

    assert_response :success
    assert_select "[data-controller=?]", "clar-clamp"
    assert_select ".clar-clamp[data-clar-clamp-target=?]", "text"
    # Hidden until the controller measures that the text really is clipped.
    assert_select "button.clar-clamp-toggle[hidden][data-action=?]", "clar-clamp#toggle"
    # The whole prompt is in the DOM — clamping is visual, so nothing is lost.
    assert_select "body", /Watch the board\./
  end

  test "each alert rule card renders a pause switch, and a paused rule reads as paused" do
    project = tasks(:jira_task).project
    post switch_workshop_project_path, params: { project_id: project.id }
    rule = AlertRule.create!(
      workspace: @workspace, project: project, notify_enabled: false,
      name: "QA column watch", prompt: "Watch the QA column.",
      frequency: "daily", run_at_time: "13:00"
    )

    get workshop_process_path(tab: "alerts")
    assert_response :success
    assert_select "form[action=?] button.clar-toggle[aria-checked=?]",
                  toggle_active_workshop_alert_rule_path(rule), "true"
    assert_select "body", { text: /Paused/, count: 0 }

    rule.update_column(:active, false)
    get workshop_process_path(tab: "alerts")

    assert_response :success
    assert_select "form[action=?] button.clar-toggle[aria-checked=?]",
                  toggle_active_workshop_alert_rule_path(rule), "false"
    assert_select "body", /Paused/
    # A paused rule is only stopped, never stripped: its prompt and schedule
    # stay on the card so it can be resumed with one click.
    assert_select "body", /Watch the QA column\./
    assert_select "body", /Daily · 13:00/
  end

  test "each alert rule card has a Run now button" do
    project = tasks(:jira_task).project
    post switch_workshop_project_path, params: { project_id: project.id }
    rule = AlertRule.create!(
      workspace: @workspace, project: project, notify_enabled: false,
      name: "QA column watch", prompt: "Watch the QA column.",
      frequency: "daily", run_at_time: "13:00"
    )

    get workshop_process_path(tab: "alerts")

    assert_response :success
    assert_select "form[action=?] button", run_now_workshop_alert_rule_path(rule), text: /Run now/
  end

  test "AI Alerts empty state renders without error" do
    get workshop_process_path(tab: "alerts")

    assert_response :success
    assert_select "body", /No alert rules yet/
  end

  private

  def dom_id_for_history(rule)
    "clar-alert-history-#{rule.id}"
  end
end
