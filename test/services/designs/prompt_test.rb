require "test_helper"

class Designs::PromptTest < ActiveSupport::TestCase
  # Hard-wrapped prose is read with its lines joined.
  def base = Designs::Prompt::BASE.squish

  test "the system prompt names the rules a turn must follow" do
    text = Designs::Prompt.system_text(project: projects(:jira_project))
    [ "design-system/", "components/", "designs/", "runtime/", "<x-include", "designs/contexts.json",
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

  test "the base prompt states how to build: components, tokens, data, contexts, manifest, runtime, markup" do
    [ "A screen never copies a component's markup", "add it to components/", "include it in both places",
      "design-system/theme.css", "fake data", "Vary it by context",
      "Add a dimension or a value only when the person asks",
      "designs/tasks/<slug>.json",
      "<script src=\"runtime/flosis.js\"></script>",
      "<button>", "<a href>", "<label>" ].each { |rule| assert_includes base, rule }
  end

  # Ruling P2-R14: the rules that the runtime and the guard depend on.
  test "the base prompt states the paths, ids, runtime and link rules" do
    [ "Paths inside a component are relative to the repo root",
      "use only letters, digits, _ and -",
      "README.md, index.html and runtime/ belong to Flosis",
      "A link's own ?ctx= is replaced by the active contexts",
      "switches contexts in the preview's picker" ].each { |rule| assert_includes base, rule }
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
      "Put classes and data-ctx-* on a wrapper element" ].each { |rule| assert_includes base, rule }
  end

  # Ruling P2-R17 (Minor 1 and 3): the setup run owns the listing pages, and
  # Claude's tools cannot delete a file.
  test "the base prompt leaves the setup run's pages alone and says how to retire a screen" do
    [ "belong to the setup run", "list this task's screens in its manifest",
      "but not delete or rename them",
      "to retire a screen, drop it from the manifest and say so in your summary" ].each do |rule|
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

  test "a thread with no task and no screen in view says only what it is and what is asked" do
    thread = DesignThread.new(project: projects(:jira_project), title: "x", branch: "design/x")
    assert_equal [ "## Thread", "## Request" ], Designs::Prompt.thread_message(thread: thread, request: "Do it").scan(/^## .+$/)
  end

end
