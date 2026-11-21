# Finish · Update Jira & Create branch (Kacper, 2026-11-21; answer (a): for
# every task whose project has Jira or GitHub). Jira first: it may create the
# ticket and give the task the key that names its branch and folder. Then the
# task's branch with its file for the developer (TaskBranch), then Ready. A
# Jira failure stops everything; a branch failure does not, since Jira is
# written by then: Ready says why and offers to try again. A project with
# neither finishes locally, as before.
class TaskFinish
  # [jira, github] for a project. Jira only for a project linked to it: the
  # server's own Jira login (.env) makes every project's credentials look
  # configured (review C1; ProjectMcpConfig and IntegrationHealthJob ask the
  # same).
  def self.integrations(project)
    credentials = ProjectCredentials.new(project)
    [ project.jira_connected? && credentials.jira_configured?, credentials.github_configured? ]
  end

  def initialize(task, writer: JiraWriter.for(task.project), branch: ->(task) { TaskBranch.new(task) })
    @task = task
    @writer = writer
    @branch = branch
  end

  # { ok:, error:, toast: }
  def run!
    jira, github = self.class.integrations(@task.project)
    return finish_locally unless jira || github

    had_key = @task.external_reference.present?
    warning = nil
    if jira
      result = push_to_jira
      return { ok: false, error: "Couldn't write to Jira: #{result[:error]}", toast: nil } unless result[:ok]

      warning = result[:warning]
      @task.reload
    end
    branched_before = @task.code_branch_pushed_at.present?
    branch = github ? @branch.call(@task).push! : nil
    @task.reload.update!(workshop_stage: "ready", detail_saved_locally_at: (Time.current unless jira))
    { ok: true, error: nil, toast: toast(jira, had_key, branch, branched_before, warning) }
  end

  private

  def push_to_jira
    draft = @task.current_detail_draft
    return @writer.commit_detail(draft) if draft

    brief = @task.current_brief
    brief ? @writer.commit_brief(brief) : { ok: false, error: "There is no description to send yet." }
  end

  def finish_locally
    @task.update!(workshop_stage: "ready", detail_saved_locally_at: Time.current)
    { ok: true, error: nil, toast: "Saved to the task locally · finished without Jira" }
  end

  def toast(jira, had_key, branch, branched_before, warning)
    parts = []
    parts << (had_key ? "Jira updated" : "Jira ticket created · #{@task.external_reference}") if jira
    if branch
      parts << (branch[:ok] ? "branch #{branch[:branch]} #{branched_before ? 'updated' : 'created'}" : "the branch couldn't be created")
    end
    parts << "note: #{warning}" if warning.present?
    parts.join(" · ")
  end
end
