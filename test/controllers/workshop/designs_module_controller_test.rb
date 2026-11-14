require "test_helper"

# The Designs module (Workshop Designs v2), against the copy of Kacper's
# ClearBacklog-3.html and the approved master-changed mockup.
class Workshop::DesignsModuleControllerTest < ActionDispatch::IntegrationTest
  include DesignRepoTestHelper
  include ActiveJob::TestHelper

  SCREEN = ->(title, body = "") { "<html><head><title>#{title}</title></head><body><h1>#{title}</h1>#{body}</body></html>" }

  setup do
    @preview_root = Dir.mktmpdir("preview")
    ENV["DESIGNS_PREVIEW_ROOT"] = @preview_root
    workspaces(:one).update!(workshop_enabled: true)
    @project = projects(:jira_project)
    sign_in_as(users(:one))
    post switch_product_path, params: { product: "workshop" }
    post switch_workshop_project_path, params: { project_id: @project.id }
  end

  teardown do
    ENV.delete("DESIGNS_PREVIEW_ROOT")
    FileUtils.remove_entry(@preview_root)
  end

  def with_designs
    with_design_remote(@project) do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo, { "designs/candidate/apply.html" => SCREEN.("Application form"),
                            "designs/recruiter/pipeline.html" => SCREEN.("Pipeline"),
                            "design-system/theme.css" => "@theme { --color-primary: #1779ba; --radius-card: 4px; }",
                            "components/button/button.html" => "<button>{{label}}</button>" })
        @project.reload.update!(design_repo_status: "ready")
        Designs::Publisher.new(@project, repo).publish!("master", "master")
        yield repo
      end
    end
  end

  # A thread with one turn's worth of work on its branch, published.
  def thread_with_work(repo, text = "Add a counter", files = { "designs/candidate/apply.html" => SCREEN.("Application form", "<p>121 / 500</p>") }, task: nil)
    thread = task ? Designs::Threads.start_from_task!(task, user: users(:one)) : Designs::Threads.start!(project: @project, user: users(:one))
    Designs::Threads.message!(thread, user: users(:one), text: text) unless task
    thread.reload
    commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha), files)
    repo.push!(thread.branch)
    DesignTurn.update_all(status: "succeeded")
    Designs::Publisher.new(@project, repo).publish!(thread.branch, thread.branch, base: thread.base_sha)
    thread
  end

  test "the sidebar has Designs for whoever holds the Designs permission" do
    with_designs do
      get workshop_pipeline_path
      assert_select "a[href=?]", workshop_designs_overview_path, text: /Designs/
    end
  end

  test "the list shows master read-only, the library and New thread, and the canvas shows master's screen" do
    with_designs do
      get workshop_designs_overview_path
      assert_response :success
      %w[Designs Hide\ menus Design\ system Components Merge\ history BRANCHES\ ·\ 1 master Read-only No\ open\ threads.
         New\ thread View\ as Candidate Recruiter Read-only\ ·\ start\ a\ thread\ to\ change\ it Open\ in\ new\ tab].each do |copy|
        assert_includes response.body, CGI.escapeHTML(copy), copy
      end
      frame = css_select("iframe[data-designs-canvas-target=frame]").sole
      assert_equal "allow-scripts allow-forms allow-popups allow-modals", frame["sandbox"]
      assert_match %r{/design/designs/candidate/apply\.html\z}, frame["src"]
      assert_select ".clar-seg-item[title=?]", "Not available for Recruiter"
      assert_select "[data-action='designs-immersive#peekNav']", count: 1
    end
  end

  test "a thread shows its branch, how far ahead it is, its modes, and its dialogs" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      get workshop_designs_overview_path(thread: thread.id)
      assert_response :success
      [ thread.branch, "1 commit ahead", "This branch", "Master", "Changes", "Merge to master", "Describe a change…",
        "AI sees Candidate › Application form", "Merge into master?",
        "After merging, master stays read-only and further changes need a new thread.",
        "Create task · start Details Gathering", "Linked to #{thread.branch}.",
        "Scope, from design thread #{thread.branch}:" ].each do |copy|
        assert_includes response.body, CGI.escapeHTML(copy), copy
      end
      # A thread without a task offers one in its top row; the hint is the button's tooltip.
      assert_select "[data-designs-head] button.clar-tip[data-tip=?]", "Generate a task when the scope is clear. It starts in Details Gathering.",
                    text: /Generate task/
      # Only Merge merges a thread: nothing says it merges on its own.
      assert_no_match(/only merges when you merge it|merges into master when/, response.body)
    end
  end

  test "Changes shows the screen marked up against the thread's base, and lists the changed screens" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      get workshop_designs_overview_path(thread: thread.id, mode: "changes")
      assert_includes response.body, "Changed in this thread"
      assert_match %r{designs/candidate/apply\.changes\.html\z}, css_select("iframe[data-designs-canvas-target=frame]").sole["src"]
    end
  end

  # A thread's branch is published once a turn commits to it. Until then the
  # branch is master as it was, so the canvas shows master's screens, not an
  # empty "No screens here yet" for as long as the first turn takes.
  def canvas_slot
    src = css_select("iframe[data-designs-canvas-target=frame]").sole["src"]
    Designs::PreviewGrant.read(src[Designs::PreviewGrant::FORMAT])&.last
  end

  test "a task's new thread shows master's screens until its branch has work of its own" do
    with_designs do
      thread = Designs::Threads.start_from_task!(tasks(:jira_task), user: users(:one))

      get workshop_designs_overview_path(thread: thread.id)

      assert_response :success
      assert_equal "master", canvas_slot
      assert_includes response.body, "Nothing on this branch yet · showing master"
      assert_not_includes response.body, "No screens here yet"
    end
  end

  test "a thread's first message shows master's screens until its turn commits" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")

      get workshop_designs_overview_path(thread: thread.id, mode: "changes")

      assert_equal "master", canvas_slot
      assert_includes response.body, "Nothing yet."
    end
  end

  test "a branch with work of its own is never passed off as master" do
    with_designs do |repo|
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")
      thread.reload
      commit_files(repo, repo.worktree!(thread.branch, from: thread.base_sha),
                   { "designs/candidate/apply.html" => SCREEN.("Application form", "<p>121 / 500</p>") })
      DesignTurn.update_all(status: "succeeded")

      get workshop_designs_overview_path(thread: thread.id)

      assert_select "iframe[data-designs-canvas-target=frame]", count: 0
      assert_not_includes response.body, "showing master"

      Designs::Publisher.new(@project, repo).publish!(thread.branch, thread.branch, base: thread.base_sha)
      get workshop_designs_overview_path(thread: thread.id)

      assert_equal thread.branch, canvas_slot
    end
  end

  test "an empty thread says it has no changes yet and asks what should change" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      get workshop_designs_overview_path(thread: thread.id)
      assert_includes response.body, "No changes yet"
      assert_includes response.body, CGI.escapeHTML("What should change? Navigate the app on the right, AI sees the page you’re on.")
    end
  end

  test "a thread's row and banners say when its task or master changed" do
    with_designs do |repo|
      task = tasks(:jira_task)
      task.update!(project: @project, external_reference: "SP-1051", external_type: "jira", description: "Validate on blur")
      waiting = thread_with_work(repo, "x", { "designs/candidate/apply.html" => SCREEN.("Application form", "<em>mine</em>") }, task: task)
      other = thread_with_work(repo, "Stage colours on pipeline", { "designs/recruiter/pipeline.html" => SCREEN.("Pipeline", "<b>stages</b>") })
      Designs::Threads.merge!(other, user: users(:one))
      task.update!(description: "Validate on blur\nShow a counter")

      get workshop_designs_overview_path
      assert_includes response.body, "Task changed"
      assert_includes response.body, "Master changed"

      get workshop_designs_overview_path(thread: waiting.id)
      assert_includes response.body, "SP-1051 changed"
      assert_includes response.body, "since the last design update"
      # master's merges since the thread branched fold under one line, Update at hand.
      assert_select "details:not([open]) > summary", text: /master changed\s*·\s*1 merge(?!s)/
      assert_select "details:not([open]) > summary button.clar-tip[form=designs-update-master][data-tip=?]", "Update from master", text: "Update"
      assert_select "details > summary button[title]", count: 0
      assert_select "form#designs-update-master[action=?]", update_master_workshop_design_thread_path(waiting)
      assert_select "details:not([open]) a[href*=?]", "merge=", text: /Stage colours on pipeline/
      assert_not_includes response.body, "merge behind master"
      assert_no_match(/merges automatically/i, response.body)
      assert_includes response.body, "Update from master first to see the result before it lands."
    end
  end

  test "the library pages show master's tokens, components and merges" do
    with_designs do |repo|
      get workshop_designs_overview_path(tab: "system")
      assert_includes response.body, "#1779ba"
      assert_includes response.body, "design-system/theme.css"
      assert_includes response.body, "Token changes go through threads like any other design change."

      get workshop_designs_overview_path(tab: "components")
      assert_not_includes response.body, "components/button/button.html"
      assert_includes response.body, "None of master's screens uses a component yet."

      Designs::Threads.merge!(thread_with_work(repo), user: users(:one))
      get workshop_designs_overview_path(tab: "history")
      assert_includes response.body, "Threads merged into master, newest first. Click a merge to see what went in."
      assert_includes response.body, "Manual · #{users(:one).name}"
      assert_includes response.body, "SUMMARY"
    end
  end

  test "the settings drawer says what the repo holds and where the designs came from" do
    with_designs do
      get workshop_designs_overview_path
      [ "Design settings", "Changing these needs the Configuration permission.", "REPOSITORY", "STACK", "STRUCTURE",
        "INITIAL SOURCES", "acme/designs", "HTML + CSS", "inspirations/" ].each do |copy|
        assert_includes response.body, CGI.escapeHTML(copy), copy
      end
    end
  end

  test "people outside Flosis staff do not see Designs until it is switched on for the project" do
    @project.update!(designs_enabled: false)
    users(:one).update!(flosis_staff: false)
    get workshop_designs_overview_path
    assert_response :not_found
  end

  test "a thread's top row holds its task next to Hide menus, and no menu button" do
    with_designs do |repo|
      task = tasks(:jira_task)
      task.update!(project: @project, external_reference: "SP-1051", external_type: "jira")
      task.enter_pipeline!(author: users(:one), stage: "details")
      thread = thread_with_work(repo, "x", { "designs/candidate/apply.html" => SCREEN.("Application form", "<em>mine</em>") }, task: task)

      get workshop_designs_overview_path(thread: thread.id)

      assert_select "[data-designs-head]" do
        # The task's stage shows on hover, which keeps the row to one line.
        assert_select "a.clar-tip.clar-tip-below[data-tip=?]", "Details · Open task", text: "SP-1051"
        assert_select "[data-designs-immersive-target=switch]"
        # Hover hints show at once: none waits on the browser's slow title.
        assert_select "[title]", count: 0
      end
      # Hide menus is enough: the one way back to the menu is the edge tab it shows.
      assert_select "[data-action='designs-immersive#peekNav']", count: 1
      assert_select ".designs-peek-tab[data-action='designs-immersive#peekNav']"
    end
  end

  # Claude answers in Markdown: the chat shows it formatted, as a task's
  # documents are (clar-markdown). A person's message and an error read as typed.
  test "an AI reply in a thread reads as Markdown, a person's message and an error as typed" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      session = thread.chat_session
      session.chat_messages.create!(role: "assistant", kind: "summary", content: "**AI usage** is a new screen.\n\n- a month selector")
      session.chat_messages.create!(role: "user", user: users(:one), content: "Make it **bold**")
      session.chat_messages.create!(role: "assistant", kind: "error", content: "Claude returned **no** answer")

      get workshop_designs_overview_path(thread: thread.id)

      assert_select ".clar-prose[data-controller=clar-markdown]", text: "**AI usage** is a new screen. - a month selector"
      assert_includes response.body, "**AI usage** is a new screen.\n\n- a month selector", "the reply's lines reach the renderer as written"
      assert_select ".whitespace-pre-line", text: "Make it **bold**"
      assert_select ".whitespace-pre-line.clar-text-danger", text: "Claude returned **no** answer"
      assert_select "[data-controller=clar-markdown]", text: /Make it|returned/, count: 0
    end
  end

  test "a thread with nothing of its own yet offers no merge" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      Designs::Threads.message!(thread, user: users(:one), text: "Errors under the field")
      get workshop_designs_overview_path(thread: thread.id)
      assert_includes response.body, "0 commits ahead"
      assert_not_includes response.body, "Merge to master"
    end
  end


  test "the design system page shows only colour values, never anything else a theme might hold" do
    with_designs do |repo|
      dir = repo.root
      commit_files(repo, dir, { "design-system/theme.css" => "@theme { --color-primary: #1779ba; --color-evil: url(https://evil.test/x); --color-mix: rgb(1 2 3); }" })
      repo.push!("master")
      Designs::Publisher.new(@project, repo).publish!("master", "master")

      get workshop_designs_overview_path(tab: "system")
      assert_includes response.body, "background: #1779ba"
      assert_includes response.body, "background: rgb(1 2 3)"
      assert_not_includes response.body, "background: url("
    end
  end


  # Every thread merges by hand, so neither the panel nor the merge dialog
  # spends a line saying when it merges.
  test "a thread of a local task says nothing about when it merges" do
    with_designs do |repo|
      task = @project.tasks.create!(name: "Local idea")
      task.enter_pipeline!(author: users(:one), stage: "briefing")
      thread = thread_with_work(repo, "x", { "designs/candidate/apply.html" => SCREEN.("Application form", "<em>1</em>") }, task: task)
      get workshop_designs_overview_path(thread: thread.id)
      assert_includes response.body, "After merging, master stays read-only and further changes need a new thread."
      assert_no_match(/This thread merges when you merge it|This thread has no task/, response.body)
    end
  end

  test "Designs opened from a task leads back to it" do
    with_designs do
      task = tasks(:jira_task)
      task.update!(project: @project, external_reference: "SP-1051")
      task.enter_pipeline!(author: users(:one), stage: "briefing")
      get workshop_designs_overview_path(back: task.id)
      assert_select "a[href=?]", workshop_idea_path(task), text: /Back to SP-1051 · #{Regexp.escape(task.name)}/
      assert_select "a[aria-label=Back]", count: 0
    end
  end

  test "Back beside Designs leads to the page before Designs, however far the person went inside" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      get workshop_designs_overview_path, headers: { "Referer" => "http://www.example.com/workshop/reporting?tab=bugs" }
      assert_select "a[href=?][aria-label=Back]", "/workshop/reporting?tab=bugs"

      get workshop_designs_overview_path(thread: thread.id), headers: { "Referer" => "http://www.example.com/workshop/designs" }
      get workshop_designs_overview_path(tab: "history"), headers: { "Referer" => "http://www.example.com/workshop/designs?thread=#{thread.id}" }
      assert_select "a[href=?][aria-label=Back]", "/workshop/reporting?tab=bugs"

      get workshop_designs_overview_path, headers: { "Referer" => "https://elsewhere.example.org/workshop/pipeline" }
      assert_select "a[href=?][aria-label=Back]", "/workshop/reporting?tab=bugs"
    end
  end

  test "Back leads to the Workshop when nobody knows where the person came from" do
    with_designs do
      get workshop_designs_overview_path
      assert_select "a[href=?][aria-label=Back]", workshop_path
    end
  end

  test "every badge on the Designs page has the badge's own size, not its row's" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      pages = [ workshop_designs_overview_path, workshop_designs_overview_path(thread: thread.id) ]
      pages.each do |page|
        get page
        badges = css_select("[class*='clar-badge-']")
        assert badges.any?, page
        badges.each { |badge| assert_includes badge["class"].split, "clar-badge", "#{page}: #{badge.text.squish}" }
      end

      Designs::Threads.merge!(thread, user: users(:one))
      get workshop_designs_overview_path(thread: thread.id)
      css_select("[class*='clar-badge-']").each { |badge| assert_includes badge["class"].split, "clar-badge", badge.text.squish }
    end
  end

  test "Components shows only what master's screens use, straight or through another component" do
    with_design_remote(@project) do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo, { "designs/candidate/apply.html" => SCREEN.("Application form", '<x-include src="components/form-row/form-row.html"></x-include>'),
                            "designs/recruiter/pipeline.html" => SCREEN.("Pipeline", '<x-include src="components/button/button.html" label="Move"></x-include>'),
                            "components/form-row/form-row.html" => '<div><x-include src="components/button/button.html" label="Save"></x-include></div>',
                            "components/button/button.html" => "<button>{{label}}</button>",
                            "components/old-banner/old-banner.html" => "<div>Nobody shows this</div>" })
        @project.reload.update!(design_repo_status: "ready")
        Designs::Publisher.new(@project, repo).publish!("master", "master")

        get workshop_designs_overview_path(tab: "components")
        cards = css_select("[data-designs-component]").map { |card| card.text.squish }
        assert_equal 2, cards.size
        assert cards.any? { |card| card.include?("components/button/button.html") && card.include?("Used in 2 of 2 context views") }
        assert cards.any? { |card| card.include?("components/form-row/form-row.html") && card.include?("Used in 1 of 2 context views") }
        assert_not_includes response.body, "old-banner"
        assert_select "a[href=?] span", workshop_designs_overview_path(tab: "components"), text: "2"
      end
    end
  end

  test "each open thread's row offers Delete, which asks first" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      fresh = Designs::Threads.start!(project: @project, user: users(:one))

      get workshop_designs_overview_path
      form = css_select("form[action='#{workshop_design_thread_path(thread)}']").sole
      assert_equal %(Delete "Add a counter"? Its branch design/add-a-counter moves to archive/ on GitHub, and you can restore the thread for 20 days.),
                   form["data-turbo-confirm"]
      assert_select form, "input[name=_method][value=delete]"
      assert_select form, "button[title=?]", "Delete thread"
      assert_equal %(Delete "New thread"?), css_select("form[action='#{workshop_design_thread_path(fresh)}']").sole["data-turbo-confirm"]
    end
  end

  test "deleted threads wait under Deleted with Restore and the days they have left" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      travel_to(3.days.ago) { Designs::Threads.delete!(thread, user: users(:one)) }

      get workshop_designs_overview_path
      assert_includes response.body, "BRANCHES · 1"
      deleted = css_select("details[data-designs-deleted]").sole
      assert_select deleted, "summary", text: /Deleted · 1/
      assert_select deleted, "*", text: "Add a counter"
      assert_select deleted, "*", text: "Deleted 3 days ago · 17 days left"
      assert_select deleted, "form[action=?] button", restore_workshop_design_thread_path(thread), text: "Restore"
      assert_select "a[href=?]", workshop_designs_overview_path(thread: thread.id), count: 0
    end
  end

  test "the left column has an edge to drag wider or narrower, and a double-click puts it back" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      [ workshop_designs_overview_path, workshop_designs_overview_path(thread: thread.id) ].each do |page|
        get page
        grid = css_select("[data-designs-module]").sole
        assert_includes grid["data-controller"].split, "designs-resize"
        assert_includes grid["style"], "grid-template-columns: var(--designs-list-width, clamp(280px, 26%, 340px)) minmax(0, 1fr);"
        edge = css_select("[data-designs-module] > div > [role=separator]").sole
        assert_equal "pointerdown->designs-resize#start dblclick->designs-resize#reset", edge["data-action"]
      end
    end
  end

  # -- a turn in the chat, as it runs and after (Designs::TurnActivity) --

  def steps(*texts)
    texts.each_with_index.map { |text, i| { "at" => i * 10, "kind" => text.start_with?("Reading") ? "read" : "say", "text" => text } }
  end

  def chat(thread)
    get workshop_designs_overview_path(thread: thread.id, frame: "messages")
    assert_response :success
    response.body
  end

  test "a running turn shows its last steps as they come, the earlier ones folded, and Stop" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      turn = Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")
      turn.update!(status: "running", started_at: 3.minutes.ago,
                   activity: steps("Reading designs/a.html", "Reading designs/b.html", "Let me check the form.",
                                   "Reading designs/c.html", "Reading designs/d.html", "Reading designs/e.html",
                                   "Reading designs/f.html", "Reading designs/g.html"))

      body = chat(thread)

      assert_select "[data-turn-id=?]", turn.id.to_s do
        assert_select "*", text: /Working · 3 min/
        assert_select "li", text: "Reading designs/g.html"
        assert_select "li", text: "Let me check the form."
        assert_select "details[data-keep=?] summary", "turn-#{turn.id}-earlier", text: "2 earlier steps"
        assert_select "form[action=?] input[name=turn][value=?]", stop_workshop_design_thread_path(thread), turn.id.to_s
      end
      assert_operator body.index("Add a counter"), :<, body.index("Working · 3 min"), "the request, then its turn"
      assert_select "[data-designs-poll-active-value=true]"
    end
  end

  test "a turn that has been quiet for a while is thinking, and one asked to stop says so, with no Stop" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      turn = Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")
      turn.update!(status: "running", started_at: 2.minutes.ago, activity: steps("Reading designs/a.html"))

      assert_includes chat(thread), "Thinking"

      turn.update!(stop_requested_at: Time.current, stop_requested_by: "Kacper")
      chat(thread)

      assert_select "[data-turn-id=?]", turn.id.to_s, text: /Stopping/
      assert_select "form[action=?]", stop_workshop_design_thread_path(thread), count: 0
    end
  end

  test "a turn that waits offers Stop too" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      turn = Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")

      chat(thread)

      assert_select "[data-turn-id=?]", turn.id.to_s, text: /Waiting to start/
      assert_select "form[action=?]", stop_workshop_design_thread_path(thread)
    end
  end

  test "a finished turn folds to how long it took and how many steps, before its reply" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      turn = Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")
      turn.update!(status: "succeeded", started_at: 13.minutes.ago, finished_at: 1.minute.ago,
                   activity: steps("Reading designs/a.html", "Let me check the form."))
      thread.chat_session.chat_messages.create!(role: "assistant", kind: "summary", content: "Added a character counter.")

      body = chat(thread)

      assert_select "[data-turn-id=?] details summary", turn.id.to_s, text: /Worked 12 min · 2 steps/
      assert_select "[data-turn-id=?] details li", turn.id.to_s, count: 2
      assert_operator body.index("Worked 12 min"), :<, body.index("Added a character counter."), "its steps, then its reply"
      assert_select "form[action=?]", stop_workshop_design_thread_path(thread), count: 0
      assert_select "[data-designs-poll-active-value=false]"
    end
  end

  test "the chat's last turn that failed offers Try again, until another one runs" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      failed = Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")
      failed.update!(status: "failed", error: DesignTurn::INTERRUPTED, started_at: 50.minutes.ago, finished_at: 1.minute.ago)

      chat(thread)

      assert_select "form[action=?] button", retry_workshop_design_thread_path(thread), text: /Try again/
      assert_select "[data-turn-id=?]", failed.id.to_s, { text: /#{Regexp.escape(DesignTurn::INTERRUPTED)}/ },
                    "a turn that was cut off has no message to say so"

      Designs::Threads.retry!(thread, user: users(:one))
      chat(thread)

      assert_select "form[action=?]", retry_workshop_design_thread_path(thread), count: 0
    end
  end

  test "a turn from before turns kept their steps adds nothing to the chat" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      turn = Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")
      turn.update!(status: "succeeded", started_at: 5.minutes.ago, finished_at: 1.minute.ago)

      chat(thread)

      assert_select "[data-turn-id=?]", turn.id.to_s, count: 0
    end
  end

  test "the merge dialog says components come first when the thread's turns made screens since" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      get workshop_designs_overview_path(thread: thread.id)
      assert_not_includes response.body, "Flosis first makes components"

      DesignTurn.where(chat_session: thread.chat_session).update_all(commit_sha: "abc1234")
      get workshop_designs_overview_path(thread: thread.id)
      assert_includes response.body, "Flosis first makes components"
    end
  end

  test "a components turn before a merge says so while it runs" do
    with_designs do |repo|
      thread = thread_with_work(repo)
      message = thread.chat_session.chat_messages.create!(role: "user", kind: "request", content: "Make components", user: users(:one))
      turn = DesignTurn.create!(chat_session: thread.chat_session, chat_message: message, kind: "components", then_merge: "manual",
                                status: "running", started_at: 1.minute.ago)

      chat(thread)

      assert_select "[data-turn-id=?]", turn.id.to_s, text: /Making components before merging · 1 min/
    end
  end

  # The second message waits while the first turn runs: its turn comes after
  # the first turn's reply, where it starts.
  test "a turn sits in the chat where it started, after the reply of the turn before it" do
    with_designs do
      thread = Designs::Threads.start!(project: @project, user: users(:one))
      first = Designs::Threads.message!(thread, user: users(:one), text: "Add a counter")
      first.update!(status: "running", started_at: Time.current)
      travel 1.minute
      second = Designs::Threads.message!(thread, user: users(:one), text: "And a search box")
      travel 1.minute
      first.update!(status: "succeeded", finished_at: Time.current, activity: steps("Reading designs/a.html"))
      thread.chat_session.chat_messages.create!(role: "assistant", kind: "summary", content: "Added a counter.")
      travel 10.seconds
      second.update!(status: "running", started_at: Time.current, activity: steps("Reading designs/b.html"))

      body = chat(thread)

      at = ->(text) { body.index(text) or flunk("#{text} is not in the chat") }
      assert_equal [ "Add a counter", "data-turn-id=\"#{first.id}\"", "And a search box", "Added a counter.", "data-turn-id=\"#{second.id}\"" ],
                   [ "Add a counter", "data-turn-id=\"#{first.id}\"", "And a search box", "Added a counter.", "data-turn-id=\"#{second.id}\"" ].sort_by(&at)
    end
  end
end
