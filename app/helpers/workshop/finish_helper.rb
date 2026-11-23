# What Finish will do for a task, in its button and in the accepted-designs
# modal (Kacper, 2026-11-21): by whether the project has Jira and a GitHub
# repo, whether the task has its ticket, and whether its branch exists.
module Workshop::FinishHelper
  def finish_label(task)
    jira, github = finish_integrations(task)
    return "Finish · go to Ready" unless jira || github

    ticket = task.external_reference.present?
    branched = task.code_branch_pushed_at.present?
    return(ticket ? "Finish · Update Jira" : "Finish · Create Jira ticket") unless github
    return(branched ? "Finish · Update branch" : "Finish · Create branch") unless jira
    return "Finish · Update Jira & branch" if branched

    ticket ? "Finish · Update Jira & Create branch" : "Finish · Create Jira ticket & branch"
  end

  # Neither Jira nor GitHub: Finish stays the local save it was.
  def finish_locally?(task)
    jira, github = finish_integrations(task)
    !(jira || github)
  end

  # In words anyone reads at once (Kacper, 2026-11-23).
  def finish_whats_left(task)
    jira, github = finish_integrations(task)
    ticket, branch = finish_places(task)
    if jira && github then "Finish puts this description in #{ticket} and in #{branch}, so a developer can start right away."
    elsif jira then "Finish puts this description in #{ticket}."
    elsif github then "Finish puts this description in #{branch}, so a developer can start right away."
    else "Finish saves the task here."
    end
  end

  # What Finish is doing once clicked, while the page waits for it (Kacper,
  # 2026-11-23: "po kliknięciu też nie wiadomo co się dzieje").
  def finish_doing(task)
    jira, github = finish_integrations(task)
    ticket, branch = finish_places(task)
    if jira && github then "Putting the description in #{ticket} and in #{branch}"
    elsif jira then "Putting the description in #{ticket}"
    elsif github then "Putting the description in #{branch}"
    else "Saving the task"
    end
  end

  # "<branch> · tasks/<KEY>/<key>.md", or nil without GitHub.
  def finish_target(task)
    _, github = finish_integrations(task)
    return unless github

    "#{task.code_branch.presence || task.suggested_branch} · #{TaskFile.new(task).path}"
  end

  private

  # Where Finish puts the description: the ticket and the branch, new or the task's own.
  def finish_places(task)
    [ task.external_reference.present? ? "the Jira ticket" : "a new Jira ticket",
      task.code_branch_pushed_at.present? ? "the task's branch on GitHub" : "a new branch on GitHub" ]
  end

  def finish_integrations(task)
    TaskFinish.integrations(task.project)
  end
end
