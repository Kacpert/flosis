# Replays Designs turns on the server with the prompts, flags and bounds a
# real turn gets, and prints what each run took: the speed plan's benchmarks
# B1 and B2 (2026-11-27). Nothing is committed, pushed or published: each run
# works in a temporary copy of the design repo at a commit, removed afterwards
# with the CLI's transcripts of it. The AI's cost is recorded as any run's is,
# so Consumption shows it, as "Benchmark · …".
#
#   RAILS_ENV=production bin/rails runner script/designs_benchmark.rb b1 <transcript of thread 6's first session>
#   RAILS_ENV=production bin/rails runner script/designs_benchmark.rb b2
#
# b1: thread 6's first message, turns 97 and 98: the plan, then the design
#     that carried on from it, from the commit the thread started from. The
#     task's description and the screen in view come from that session's
#     first prompt, as they were then.
# b2: a one-screen text change on master, then the same follow-up twice: in
#     the warm session it ran in (B2a), and in a new session told the thread
#     so far (B2b).
require "securerandom"
require "tempfile"
require "tmpdir"

module DesignsBenchmark
  THREAD_ID = 6
  PLAN_TURN_ID = 97
  DESIGN_TURN_ID = 98
  B2_SCREEN = "designs/admin/designs-thread.html".freeze
  FOLDERS = %w[components/ designs/ design-system/ inspirations/ runtime/].freeze
  ROOT_FILES = %w[README.md index.html].freeze
  CONTEXT_KEYS = %w[input_tokens cache_read_input_tokens cache_creation_input_tokens].freeze

  # What one run did, from the events the CLI streamed.
  class Stats
    attr_accessor :seconds, :answer, :session_id

    def initialize
      @own = {}
      @sub = {}
      @tools = Hash.new(0)
      @context = 0
    end

    def <<(event)
      return unless event.is_a?(Hash)

      @result = event if event["type"] == "result"
      return unless event["type"] == "assistant"

      sub = event["parent_tool_use_id"].present?
      message = event["message"] || {}
      usage = message["usage"] || {}
      (sub ? @sub : @own)[message["id"]] = usage
      @tools[sub ? :sub : :own] += Array(message["content"]).count { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
      @context = [ @context, CONTEXT_KEYS.sum { |key| usage[key].to_i } ].max unless sub
    end

    def summary = Designs::TurnOutput.parse(answer.to_h[:response].to_s).summary

    def row(name, files)
      output = (@own.values + @sub.values).sum { |usage| usage["output_tokens"].to_i }
      format("%-10s %6.0f s  requests %3d+%-3d  tool calls %3d+%-3d  context %7d  output %7d  $%6.2f  files %3d",
             name, seconds, @own.size, @sub.size, @tools[:own], @tools[:sub], @context, output, @result.to_h["total_cost_usd"].to_f, files)
    end
  end

  module_function

  def run(name, transcript)
    case name
    when "b1" then b1(transcript)
    when "b2" then b2
    else puts "usage: bin/rails runner script/designs_benchmark.rb b1 <transcript.jsonl> | b2"
    end
  end

  def b1(transcript)
    real = DesignThread.find(THREAD_ID)
    first = first_prompt(transcript)
    focus = focus_in(first)
    description = section(first, "Current description")
    if real.task && description && description.strip != Designs::CurrentDescription.for(real.task).to_s.strip
      puts "The task's description changed since turn #{PLAN_TURN_ID}: the benchmark uses the one that turn had."
      Designs::CurrentDescription.define_singleton_method(:for) { |_task| description }
    end
    subject, thread = subject_for(real, title: real.title, task: real.task, focus: focus)
    repo = Designs::Repo.new(real.project)
    dir = tree_at(repo, real.base_sha)
    path = ("designs/#{focus[:context]}/#{focus[:screen]}.html" if focus)
    plan = turn(subject, "B1 plan", kind: "plan", worktree: dir,
                prompt: Designs::Prompt.thread_message(thread: thread, request: DesignTurn.find(PLAN_TURN_ID).chat_message.content,
                                                       repo_map: Designs::RepoMap.text(dir, focus: path, full: true), plan: true))
    design = turn(subject, "B1 design", kind: "design", worktree: dir, resume: plan.session_id,
                  prompt: Designs::Prompt.thread_message(thread: thread, request: DesignTurn.find(DESIGN_TURN_ID).chat_message.content,
                                                         repo_map: Designs::RepoMap.text(dir, focus: path), design: true, after_plan: true))
    puts plan.row("B1 plan", 0)
    puts design.row("B1 design", changed(repo, real.base_sha, dir))
    puts "B1 round: #{(plan.seconds + design.seconds).round} s. Baseline: plan 35 s and design 1374 s; design $11.19, " \
         "283 tool calls, context 81k to 385k."
  ensure
    cleanup(dir)
  end

  def b2
    real = DesignThread.find(THREAD_ID)
    subject, thread = subject_for(real, title: "Benchmark B2", task: nil, focus: { context: "admin", screen: "designs-thread" })
    repo = Designs::Repo.new(real.project)
    ref = repo.head(Designs::Repo::MASTER)
    dir = tree_at(repo, ref)
    request = "In #{B2_SCREEN}, change the page's <title> text to \"Design threads\"."
    first = turn(subject, "B2 first", kind: "design", worktree: dir,
                 prompt: Designs::Prompt.thread_message(thread: thread, request: request,
                                                        repo_map: Designs::RepoMap.text(dir, focus: B2_SCREEN, full: true), design: true))
    first_files = changed(repo, ref, dir)
    cold_dir = Dir.mktmpdir("designs-benchmark")
    FileUtils.cp_r("#{dir}/.", cold_dir)
    follow_up = "Make that title \"Threads\" instead."
    warm = turn(subject, "B2a warm", kind: "design", worktree: dir, resume: first.session_id,
                prompt: Designs::Prompt.thread_message(thread: thread, request: follow_up, repo_map: Designs::RepoMap.text(dir, focus: B2_SCREEN),
                                                       design: true, may_propose: true))
    cold = turn(subject, "B2b new", kind: "design", worktree: cold_dir,
                prompt: Designs::Prompt.thread_message(thread: thread, request: follow_up,
                                                       repo_map: Designs::RepoMap.text(cold_dir, focus: B2_SCREEN, full: true),
                                                       design: true, may_propose: true,
                                                       history: "The person: #{request}\n\nYou: #{first.summary}", changed: "- #{B2_SCREEN}"))
    puts first.row("B2 first", first_files)
    puts warm.row("B2a warm", changed(repo, ref, dir))
    puts cold.row("B2b new", changed(repo, ref, cold_dir))
  ensure
    cleanup(dir, cold_dir)
  end

  # A session and a thread that are never saved, on the real thread's project,
  # for the subject that makes a real turn's prompt and bounds.
  def subject_for(real, title:, task:, focus:)
    session = ChatSession.new(project: real.project, workspace: real.project.workspace, user: real.author, purpose: "designs_thread",
                              claude_session_id: SecureRandom.uuid, codebase_path: "/tmp")
    thread = session.build_design_thread(project: real.project, task: task, author: real.author, title: title, branch: real.branch,
                                         base_sha: real.base_sha, focus_context: focus&.dig(:context),
                                         focus_screen: focus&.dig(:screen), focus_state: focus&.dig(:state))
    [ Designs::Subject.for(session), thread ]
  end

  # One run of the CLI, as Designs::TurnJob#ask_claude makes it.
  def turn(subject, name, kind:, worktree:, prompt:, resume: nil)
    bounds = Designs::TurnJob.new.send(:bounds, DesignTurn.new(kind: kind), subject)
    stats = Stats.new
    stats.session_id = resume || SecureRandom.uuid
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Tempfile.create([ "flosis-designs-benchmark", ".md" ]) do |system_prompt|
      system_prompt.write(subject.system_text)
      system_prompt.close
      with_app(subject) do |app|
        subject.with_mcp(worktree, read_only: kind == "plan") do |mcp_config|
          cli = ClaudeCliService.new(codebase_path: worktree, allowed_tools: bounds[:allowed], restricted: true, api_key: subject.api_key,
                                     append_system_prompt_file: system_prompt.path, add_dirs: [ app ].compact,
                                     max_budget_usd: bounds[:budget], timeout: bounds[:timeout], mcp_config: mcp_config,
                                     tools: bounds[:tools], effort: bounds[:effort], attribution: attribution(subject, name))
          stats.answer =
            if resume
              cli.resume_session(session_id: resume, prompt: prompt) { |event| stats << event }
            else
              cli.start_session(prompt: prompt, new_session_id: stats.session_id) { |event| stats << event }
            end
        end
      end
    end
    stats.seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    stats
  end

  def with_app(subject, &block)
    subject.app_copy? ? Designs::AppCopy.open(subject.project, &block) : yield(nil)
  end

  def attribution(subject, name)
    project = subject.project
    AiRun::Attribution.new(workspace: project.workspace, project: project, area: "designs", item_label: "Benchmark · #{name}")
  end

  # The design repo at ref, in a folder of its own.
  def tree_at(repo, ref)
    dir = Dir.mktmpdir("designs-benchmark")
    paths = FOLDERS.flat_map { |prefix| repo.ls_files(ref, prefix) } + ROOT_FILES
    paths.each do |path|
      body = repo.read_file(ref, path) or next
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.binwrite(File.join(dir, path), body)
    end
    dir
  end

  # The design files the runs left different from ref, new ones included.
  def changed(repo, ref, dir)
    Dir.glob("**/*", base: dir).count do |path|
      next false unless path.start_with?("designs/", "components/", "design-system/") && File.file?(File.join(dir, path))

      before = repo.read_file(ref, path)
      before.nil? || before.b != File.binread(File.join(dir, path))
    end
  end

  # The session's first prompt: the plan turn's whole message.
  def first_prompt(path)
    File.foreach(path) do |line|
      event = JSON.parse(line) rescue next
      next unless event["type"] == "user"

      content = event.dig("message", "content")
      text = content.is_a?(String) ? content : Array(content).filter_map { |block| block["text"] if block.is_a?(Hash) }.join
      return text if text.include?("## Thread")
    end
    raise ArgumentError, "no turn's prompt in #{path}"
  end

  def section(text, heading) = text[/^## #{Regexp.escape(heading)}\n(.*?)(?=\n## |\z)/m, 1]

  def focus_in(text)
    match = section(text, "The person is looking at").to_s.match(%r{\(designs/([\w-]+)/([\w-]+)\.html(?:#([\w-]+))?\)}) or return
    { context: match[1], screen: match[2], state: match[3] }
  end

  def cleanup(*dirs)
    dirs.compact.each do |dir|
      FileUtils.rm_rf(dir)
      Dir.glob(File.expand_path("~/.claude/projects/*#{File.basename(dir)}*")).each { |path| FileUtils.rm_rf(path) }
    end
  end
end

DesignsBenchmark.run(ARGV[0], ARGV[1])
