# Sets a specific Brief version as the task's current brief (briefing stage).
# Always writes the brief's plain text back to `tasks.description` so the
# rest of the app (which reads `description`, not briefs) stays in sync.
# For a Jira-linked idea this ALSO pushes the same text to the Jira issue's
# description via JiraWriter's client — independent of whether the brief has
# ever been "Briefed" (mockup semantics: any Jira-linked idea's Jira
# description should always mirror whichever version is current).
class Workshop::VersionsController < Workshop::BaseController
  def make_current
    @idea = current_workshop_project.tasks.pipeline.find(params[:idea_id])
    brief = @idea.briefs.find(params[:id])

    brief.make_current!
    @idea.update!(description: brief.content)

    if @idea.external_reference.present?
      result = JiraClient.new.update_issue_description(
        issue_key: @idea.external_reference, description_text: brief.content
      )
      unless result[:ok]
        flash[:clar_toast] = "v#{brief.version} set as current locally · Jira update failed: #{result[:error]}"
        redirect_to workshop_idea_path(@idea, stage: "briefing", v: brief.version) and return
      end
      flash[:clar_toast] = "v#{brief.version} set as current · Jira description updated"
    else
      flash[:clar_toast] = "v#{brief.version} set as current · local description updated"
    end

    redirect_to workshop_idea_path(@idea, stage: "briefing", v: brief.version)
  end
end
