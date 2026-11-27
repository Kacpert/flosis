require "test_helper"

class Designs::PromptTest < ActiveSupport::TestCase
  # Hard-wrapped prose is read with its lines joined.
  def base = Designs::Prompt::BASE.squish

  test "the system prompt names the rules a turn must follow" do
    text = Designs::Prompt.system_text(project: projects(:jira_project))
    [ "design-system/", "components/", "designs/", "runtime/", "<x-include", "designs/<context>/",
      "<summary>", "<missing>", "<context>", projects(:jira_project).name ].each { |fact| assert_includes text, fact }
  end

  test "every turn carries the task, its description, the manifest path and the request" do
    task = tasks(:jira_task)
    task.update!(external_reference: "REC-1", description: "Archive offers")
    message = Designs::Prompt.turn_message(task: task, request: "Add an archive tab")
    assert_match(/## Task\nREC-1 — #{Regexp.escape(task.name)}/, message)
    assert_includes message, "Archive offers"
    assert_includes message, "designs/tasks/REC-1.json"
    assert message.rstrip.end_with?("Add an archive tab")
  end

  test "the base prompt is frozen and names the four places a turn may change" do
    assert_predicate Designs::Prompt::BASE, :frozen?
    assert_equal 4, Designs::LeakGuard::DESIGN_DIRS.size
    Designs::LeakGuard::DESIGN_DIRS.each { |path| assert_includes Designs::Prompt::BASE, path }
  end

  test "the base prompt states how to build: components, tokens, data, contexts, runtime, markup" do
    [ "A screen never copies a component's markup", "add it to components/", "include it in both places",
      "design-system/theme.css", "fake data", "Add a context only when the person asks",
      "<script src=\"../../runtime/flosis.js\"></script>", "Give every screen a <title>",
      "<button>", "<a href>", "<label>" ].each { |rule| assert_includes base, rule }
    [ "contexts.json", "manifest", "?ctx=", "data-ctx" ].each { |gone| assert_not_includes base, gone }
  end

  # Ruling P2-R14: the rules that the runtime and the guard depend on.
  test "the base prompt states the paths, ids, runtime and link rules" do
    [ "Paths inside a component are relative to the repo root",
      "use only letters, digits, _ and -",
      "README.md, index.html and runtime/ belong to Flosis",
      "A link to a screen that does not exist yet is fine" ].each { |rule| assert_includes base, rule }
  end

  # Ruling P2-R17. Both fail without a word in the browser (reproduced against
  # flosis.js): HTML ignores the slash of <x-include ... />, so what follows it
  # becomes its children and is dropped unless the component has a slot; and the
  # include itself is replaced by the component, so its own class or
  # data-ctx-show is gone and a gated component shows to everyone.
  test "the base prompt warns about the two ways an include silently drops markup" do
    [ "Always close an include with </x-include>",
      "never write <x-include ... />",
      "Only placeholders read an include's attributes",
      "Put classes on a wrapper element" ].each { |rule| assert_includes base, rule }
  end

  # Ruling P2-R17 (Minor 1 and 3): the setup run owns the listing pages, and
  # Claude's tools cannot delete a file.
  test "the base prompt leaves Flosis's pages alone and says how to retire a screen" do
    [ "README.md, index.html and runtime/ belong to Flosis", "but not delete or rename them",
      "to retire a screen, say so in your summary" ].each do |rule|
      assert_includes base, rule
    end
  end

  test "the base prompt states the reply protocol, and what a missing requirement is" do
    [ "exactly one <summary>", "<context>", "<missing>", "a requirement the person has not decided" ].each do |rule|
      assert_includes base, rule
    end
  end

  # The guard refuses twelve words in a row from the base prompt, and a new
  # screen starts as a copy of the repo's own pages: a prompt that quoted the
  # template would get every such turn refused.
  test "the files of a new design repo hold no passage of the base prompt" do
    guard = Designs::LeakGuard.new(forbidden_texts: [ Designs::Prompt::BASE ], flosis_files: true)
    Project::DESIGN_BASE_KITS.each do |kit|
      project = projects(:jira_project)
      project.design_base_kit = kit
      Dir.mktmpdir("prompt") do |dir|
        Designs::Template.render_into(dir, project: project)
        changes = Dir.glob("**/*", base: dir).select { |path| File.file?(File.join(dir, path)) }
                     .map { |path| Designs::Repo::Change.new(path: path, added_text: File.read(File.join(dir, path))) }
        assert_empty guard.check(changes), kit
      end
    end
  end

  # Plan 3: the prompt starts with the library's composition, not with BASE.
  test "the system prompt is the library's composition, then the project's name and its context" do
    project = projects(:jira_project)
    project.context_info = "An ATS for recruiters. The users are HR managers."
    library = Designs::Library.compose(project).text
    text = Designs::Prompt.system_text(project: project)
    assert text.start_with?(library)
    assert_includes text.delete_prefix(library), project.name
    assert_includes text.delete_prefix(library), "An ATS for recruiters. The users are HR managers."
  end

  test "the system prompt is made of the composition it is given" do
    composition = Designs::Library::Composition.new(text: "# Base\nGiven.", texts: [ "Given." ], version_ids: [])
    assert Designs::Prompt.system_text(project: projects(:jira_project), composition: composition).start_with?("# Base\nGiven.\n")
  end

  test "a project without context still gets its name, and says so" do
    project = projects(:jira_project)
    project.context_info = nil
    tail = Designs::Prompt.system_text(project: project).delete_prefix(Designs::Library.compose(project).text)
    assert_includes tail, project.name
    assert_includes tail, "No context"
  end

  test "the turn's sections come in order, and the description is the current one" do
    task = tasks(:jira_task)
    task.update!(external_reference: "REC-1", description: "from jira")
    task.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, content: "from the details draft", origin: "ai").make_current!
    message = Designs::Prompt.turn_message(task: task, request: "Add an archive tab")
    assert_equal [ "## Task", "## Current description", "## Manifest path", "## Request" ], message.scan(/^## .+$/)
    assert_includes message, "## Current description\nfrom the details draft\n"
    assert_not_includes message, "from jira"
    assert_includes message, "## Manifest path\ndesigns/tasks/REC-1.json\n"
  end

  test "a task with no description yet says so, and one with no Jira key is named after its id" do
    task = tasks(:local_task)
    task.update!(description: nil)
    message = Designs::Prompt.turn_message(task: task, request: "Sketch it")
    assert_includes message, "## Task\ntask-#{task.id} — #{task.name}\n"
    assert_includes message, "## Current description\n(none yet)\n"
    assert_includes message, "## Manifest path\ndesigns/tasks/task-#{task.id}.json\n"
  end

  test "a thread's turn says where the person is looking, the task and its description, and the request last" do
    task = tasks(:jira_task)
    task.update!(external_reference: "SP-1051", description: "Validate on blur")
    thread = DesignThread.new(project: task.project, task: task, title: "Inline validation", branch: "design/SP-1051-inline-validation",
                              focus_context: "candidate", focus_screen: "apply")
    message = Designs::Prompt.thread_message(thread: thread, request: "Errors under the field")

    assert_equal [ "## Thread", "## The person is looking at", "## Task", "## Current description", "## Request" ], message.scan(/^## .+$/)
    assert_includes message, "design/SP-1051-inline-validation"
    assert_includes message, "designs/candidate/apply.html"
    assert_includes message, "Validate on blur"
    assert message.rstrip.end_with?("Errors under the field")
  end

  # Kacper (2026-11-22): a page's states live in its file, so the state the
  # person has open is part of where they are looking.
  test "a thread's turn names the state of the screen the person has open" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x",
                              focus_context: "candidate", focus_screen: "apply", focus_state: "errors-shown")
    message = Designs::Prompt.thread_message(thread: thread, request: "Do it")
    assert_includes message, "## The person is looking at\nCandidate › Apply, in its Errors shown state (designs/candidate/apply.html#errors-shown)\n"
  end

  # 2026-11-27: thread 6's 23-minute turn took 283 steps; 82 of its edits
  # changed under 200 characters, and 20 were repeated in a second file.
  test "a design turn carries the editing rules, and a plan and a check do not" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")

    assert_includes Designs::Prompt.thread_message(thread: thread, request: "Do it", design: true), Designs::Prompt::EDITING
    assert_not_includes Designs::Prompt.thread_message(thread: thread, request: "Plan it", plan: true), Designs::Prompt::EDITING
    assert_not_includes Designs::Prompt.thread_message(thread: thread, request: "Check", check: true), Designs::Prompt::EDITING
    [ "replace_all", "offset and", "one response", "old_string" ].each { |rule| assert_includes Designs::Prompt::EDITING, rule }
  end

  test "a component gets a preview only when it has more than one state, and a turn re-reads only the lines it changed" do
    assert_includes Designs::Prompt::COMPONENTS, "only when it has more than one state"
    assert_includes Designs::Prompt::BASE, "re-read the lines you changed"
  end

  # 2026-11-27: a turn that starts a new Claude session no longer has the one
  # that heard the thread.
  test "a new session's message carries the thread so far and the branch's changes, after the map and before the request" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")
    message = Designs::Prompt.thread_message(thread: thread, request: "Make it weekly", repo_map: "MAP", design: true,
                                             history: "The person: Add usage", changed: "- designs/admin/usage.html")

    assert_equal [ "## Thread", "## The design repo now", "## This thread so far", "## Changed on this branch", "## This turn", "## Request" ],
                 message.scan(/^## .+$/)
    assert_includes message, "The person: Add usage"
    assert_includes message, "## Changed on this branch\n- designs/admin/usage.html"
    assert_equal [ "## Thread", "## The design repo now", "## This turn", "## Request" ],
                 Designs::Prompt.thread_message(thread: thread, request: "Make it weekly", repo_map: "MAP", design: true).scan(/^## .+$/)
  end

  test "a thread with no task and no screen in view says only what it is and what is asked" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")
    assert_equal [ "## Thread", "## Request" ], Designs::Prompt.thread_message(thread: thread, request: "Do it").scan(/^## .+$/)
  end

  # Kacper, 2026-11-21: a thread starts with a proposal: how the AI reads the
  # request, where things go and each value's exact strings, asking only what
  # a standard cannot settle.
  test "a plan turn's message carries the plan's rules" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")
    message = Designs::Prompt.thread_message(thread: thread, request: "Show AI costs", plan: true)

    assert_equal [ "## Thread", "## This turn", "## Request" ], message.scan(/^## .+$/)
    assert_includes message, Designs::Prompt::PLAN
    assert_includes message, Designs::Prompt::STATES
    [ "<nav data-states>", "data-show-in", "data-hide-in", "data-open-in", "Flosis.state", "never draw one" ].each { |rule| assert_includes Designs::Prompt::STATES, rule }
    [ "change no file", "exact strings", "Proposal: ", "No doubts, designing now." ].each { |rule| assert_includes Designs::Prompt::PLAN, rule }
    assert_not_includes message, Designs::Prompt::DIRECTION_FIRST
    assert message.rstrip.end_with?("Show AI costs")
  end

  # Variant (b): a later message that brings a direction or a new thing is
  # proposed first; the answer to a proposal is built, never proposed again.
  test "a design turn that may propose is told to propose a direction first, unless it answers a plan" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")
    proposing = Designs::Prompt.thread_message(thread: thread, request: "Make costs subtle", design: true, may_propose: true)
    answering = Designs::Prompt.thread_message(thread: thread, request: "Yes", design: true, may_propose: true, after_plan: true)

    assert_includes proposing, Designs::Prompt::DIRECTION_FIRST
    assert_not_includes proposing, Designs::Prompt::AFTER_PLAN
    [ "change no file", "built at once", "This replaces what the base prompt says about never stopping to ask." ].each do |rule|
      assert_includes Designs::Prompt::DIRECTION_FIRST, rule
    end
    assert_not_includes answering, Designs::Prompt::DIRECTION_FIRST
    assert_includes answering, Designs::Prompt::AFTER_PLAN
    assert_includes Designs::Prompt::AFTER_PLAN, "plan or proposal"
  end

  # A check runs in a session of its own, so its message is what it needs:
  # the thread, its rules and the request that lists what to look at.
  test "a check turn's message holds only the thread, the check's rules and its request" do
    task = tasks(:jira_task)
    task.update!(external_reference: "SP-1051", description: "Validate on blur")
    thread = DesignThread.new(project: task.project, task: task, title: "Inline validation", branch: "design/SP-1051-inline-validation",
                              focus_context: "candidate", focus_screen: "apply")
    message = Designs::Prompt.thread_message(thread: thread, request: "Check these screens", check: true)

    assert_equal [ "## Thread", "## This turn", "## Request" ], message.scan(/^## .+$/)
    assert_includes message, Designs::Prompt::CHECK
    assert_not_includes message, Designs::Prompt::COMPONENTS
    [ "design_shot", "1160", "1024", "check_design", "Checked on screen:" ].each { |rule| assert_includes Designs::Prompt::CHECK, rule }
  end

  test "the note on what a check changed comes before This turn" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")
    message = Designs::Prompt.thread_message(thread: thread, request: "Do it", design: true,
                                             check_note: "Checked on screen: the cost now wraps at 1024 px.")

    assert_equal [ "## Thread", "## Since your last turn", "## This turn", "## Request" ], message.scan(/^## .+$/)
    assert_includes message, "Checked on screen: the cost now wraps at 1024 px."
  end

  # The skill is a Library text: the guard refuses twelve words of it in a
  # repo, and a new screen starts as a copy of the template's pages.
  test "the skill shares no twelve words with the template" do
    guard = Designs::LeakGuard.new(forbidden_texts: [ Designs::Prompt::SENIOR_DESIGNER_SKILL ], flosis_files: true)
    Project::DESIGN_BASE_KITS.each do |kit|
      project = projects(:jira_project)
      project.design_base_kit = kit
      Dir.mktmpdir("prompt") do |dir|
        Designs::Template.render_into(dir, project: project)
        changes = Dir.glob("**/*", base: dir).select { |path| File.file?(File.join(dir, path)) }
                     .map { |path| Designs::Repo::Change.new(path: path, added_text: File.read(File.join(dir, path))) }
        assert_empty guard.check(changes), kit
      end
    end
    [ "purpose", "limited attention", "(none this month)", "margins", "three short sentences" ].each do |rule|
      assert_includes Designs::Prompt::SENIOR_DESIGNER_SKILL, rule
    end
  end

  # Kacper, 2026-11-22: a design turn makes components as it builds.
  test "a design turn carries the design repo and its rules, components as it builds among them, before the request" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")
    message = Designs::Prompt.thread_message(thread: thread, request: "Do it", repo_map: "Kit: plain\n\n### Screens\n(none yet)", design: true)

    assert_equal [ "## Thread", "## The design repo now", "## This turn", "## Request" ], message.scan(/^## .+$/)
    assert_includes message, "Kit: plain"
    assert_includes message, Designs::Prompt::COMPONENTS
    assert_not_includes message, "Build the screens only"
    [ Designs::Prompt::STATES, Designs::Prompt::COPIES, Designs::Prompt::SPACE ].each { |rule| assert_includes message, rule }
    assert message.rstrip.end_with?("Do it")
  end

  # Kacper (2026-11-23): a page header of a badge, a title, a description and
  # labelled tab groups pushed the content half way down, and he wants the AI
  # to keep space without being asked. Design turns and plans keep it; a
  # check counts a header that pushes the content low as broken.
  test "design turns and plans keep the window for the content, and a check fixes a header that pushes it low" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")
    assert_includes Designs::Prompt.thread_message(thread: thread, request: "Do it", design: true), Designs::Prompt::SPACE
    assert_includes Designs::Prompt.thread_message(thread: thread, request: "Do it", plan: true), Designs::Prompt::SPACE
    assert_not_includes Designs::Prompt.thread_message(thread: thread, request: "Check", check: true), Designs::Prompt::SPACE
    [ "top third", "1160 × 860", "two short rows", "beside it", "tabs" ].each { |rule| assert_includes Designs::Prompt::SPACE, rule }
    assert_includes Designs::Prompt::CHECK, "top third"
  end
  # Accept designs (2026-11-21): the task's next description version keeps
  # the task as it is and changes only what the designs settled.
  test "the describe message keeps the structure rule and says when the description is newer" do
    task = tasks(:jira_task)
    message = Designs::Prompt.describe_message(task: task, description: "## Costs\n\nShown as $12.",
                                               conversation: "The person: use euro", ahead: { from: "v3", to: "v4" },
                                               screens: "- New · Admin › Plans (designs/admin/plans.html)")

    assert_includes message, Designs::Prompt::DESCRIBE
    assert_includes message, "Keep its structure, its order and its wording"
    assert_includes message, "## Costs\n\nShown as $12."
    assert_includes message, "The person: use euro"
    assert_includes message, "- New · Admin › Plans (designs/admin/plans.html)"
    assert_includes message, "changed after the designs were last updated (v3 → v4)"
    assert_includes message, "<description>"
    assert_not_includes Designs::Prompt.describe_message(task: task, description: "x", conversation: "", screens: "", ahead: nil),
                        "last updated"
  end
end
