# Whose AI run it is (SCRUM-70): the organization, project, area and item a
# Claude run is for, and who started it — a person, or an automation by name,
# never both. ClaudeCliService will not run without one, so no call site can
# leave its runs unrecorded. Built through the factories below, one per kind of
# run, so every call site words its item the same way.
AiRun::Attribution = Data.define(:workspace, :project, :area, :item, :item_label, :started_by, :automation) do
  def initialize(workspace:, area:, project: nil, item: nil, item_label: nil, started_by: nil, automation: nil)
    raise ArgumentError, "an AI run needs an organization" if workspace.nil?
    raise ArgumentError, "unknown AI area #{area.inspect}" unless AiRun::AREAS.key?(area)
    unless started_by.present? ^ automation.present?
      raise ArgumentError, "an AI run is started by a person or an automation, exactly one of them"
    end

    super
  end

  class << self
    # A task's key as people see it: its Jira key, else task-<id> (the name the
    # design repo gives a task without one).
    def task_key(task)
      task.external_reference.presence || "task-#{task.id}"
    end

    CHAT_LABELS = { "brief" => "Briefing", "breakdown" => "Breakdown" }.freeze

    # Briefing and Details are the task's conversation in Create Tasks; the
    # same refine chat outside the pipeline is the Jira Tasks page's ticket
    # chat. Refining a breakdown counts under AI estimates (the accepted
    # Consumption design).
    def for_task_chat(task, purpose:, user:)
      area, label =
        case purpose
        when "brief" then [ "task_conversations", "Briefing" ]
        when "breakdown" then [ "estimates", "Breakdown" ]
        else task.in_pipeline? ? [ "task_conversations", "Details Gathering" ] : [ "ticket_chat", "Chat" ]
        end
      for_task(task, area: area, label: "#{task_key(task)} · #{label}", user: user)
    end

    def for_handoff(task, user:)
      for_task(task, area: "task_conversations", label: "#{task_key(task)} · Handoff", user: user)
    end

    def for_estimate(task, user: nil)
      for_task(task, area: "estimates", label: keyed(task_key(task), task.name), user: user, automation: "AI estimate")
    end

    def for_delivered_estimate(issue)
      project = issue.project
      new(workspace: project.workspace, project: project, area: "estimates", item: issue,
          item_label: keyed(issue.jira_key, issue.title), automation: "AI estimate backfill")
    end

    def for_pr_review(review)
      project = review.project
      new(workspace: review.workspace || project&.workspace, project: project, area: "pr_reviews", item: review,
          item_label: [ "##{review.pr_number}", review.pr_title.presence ].compact.join(" "), automation: "PR review")
    end

    def for_alert_rule(rule, user: nil)
      new(workspace: rule.workspace || rule.project.workspace, project: rule.project, area: "agents", item: rule,
          item_label: "Rule · #{rule.name}", **by(user, rule.name))
    end

    def for_bug_analysis(bug, user: nil)
      project = bug.project
      new(workspace: project.workspace, project: project, area: "bug_analysis", item: bug,
          item_label: keyed(bug.jira_key, bug.task&.name), **by(user, "Bug analysis"))
    end

    def for_feature_scan(project, user: nil)
      new(workspace: project.workspace, project: project, area: "feature_scan", item: project,
          item_label: "Feature scan · #{project.github_repo.presence || project.name}", **by(user, "Feature scan"))
    end

    # A Designs turn: an import's (setup) turn is the import's, any other the
    # thread's. The person is whoever asked for the turn.
    def for_design_turn(turn)
      session = turn.chat_session
      user = turn.chat_message.user
      if session.purpose == "designs_setup" && session.design_setup
        setup = session.design_setup
        label = "Import · Designs from the app, #{I18n.l(setup.created_at.to_date, format: '%-d %b')}"
        design(setup.project, setup, label, user)
      elsif session.design_thread
        thread = session.design_thread
        design(thread.project, thread, "Thread · #{thread.title}", user)
      else
        task = session.task
        design(task.project, task, "#{task_key(task)} · Designs", user)
      end
    end

    def for_describe(turn, user:)
      thread = turn.chat_session.design_thread
      design(thread.project, thread, "Thread · #{thread.title}", user)
    end

    private

    def for_task(task, area:, label:, user:, automation: nil)
      project = task.project
      new(workspace: project.workspace, project: project, area: area, item: task, item_label: label,
          **(automation ? by(user, automation) : { started_by: user }))
    end

    def design(project, item, label, user)
      new(workspace: project.workspace, project: project, area: "designs", item: item, item_label: label,
          **by(user, "Designs"))
    end

    # A person when there is one, else the automation's name.
    def by(user, automation)
      user ? { started_by: user } : { automation: automation }
    end

    # "KEY title", without repeating a key the title already starts with.
    def keyed(key, title)
      return key.to_s if title.blank?
      return title if key.blank? || title.start_with?(key)

      "#{key} #{title}"
    end
  end
end
