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

  def finish_whats_left(task)
    jira, github = finish_integrations(task)
    ticket = task.external_reference.present? ? "the Jira ticket updated with the new description" : "a Jira ticket created with the new description"
    if jira && github then "A branch with the task for the developer to take over, and #{ticket}."
    elsif jira then "#{ticket.upcase_first}."
    elsif github then "A branch with the task for the developer to take over."
    else "Finish the task here."
    end
  end

  # "<branch> · tasks/<KEY>/<key>.md", or nil without GitHub.
  def finish_target(task)
    _, github = finish_integrations(task)
    return unless github

    "#{task.code_branch.presence || task.suggested_branch} · #{TaskFile.new(task).path}"
  end

  private

  def finish_integrations(task)
    credentials = ProjectCredentials.new(task.project)
    [ credentials.jira_configured?, credentials.github_configured? ]
  end
end
