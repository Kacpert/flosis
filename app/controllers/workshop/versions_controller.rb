# Sets a specific version as the task's current one. Shared by both stages
# that have versioned documents: briefing (Brief) and details (TaskDraft,
# source "ai" — Task 5.1). The document panel's chips post to the same
# `make_current_workshop_idea_version_path(idea, version)` regardless of
# stage; this action figures out which kind of record `params[:id]` is.
#
# Briefing (Brief): always writes the brief's plain text back to
# `tasks.description` so the rest of the app (which reads `description`, not
# briefs) stays in sync. For a Jira-linked idea this ALSO pushes the same
# text to the Jira issue's description via JiraClient — independent of
# whether the brief has ever been "Briefed" (mockup semantics: any
# Jira-linked idea's Jira description should always mirror whichever version
# is current).
#
# Details (TaskDraft): does NOT touch `tasks.description` — that column
# belongs to briefing. For a Jira-linked idea it pushes the draft's content
# to the Jira issue's description the same way, but does not touch the "AI
# actions" field (that only changes via an explicit push, JiraWriter#commit_detail).
class Workshop::VersionsController < Workshop::BaseController
  def make_current
    @idea = current_workshop_project.tasks.pipeline.find(params[:idea_id])
    brief = @idea.briefs.find_by(id: params[:id])

    if brief
      make_current_brief(brief)
    else
      draft = @idea.task_drafts.by_source(TaskDraft::REFINE_SOURCE).find(params[:id])
      make_current_draft(draft)
    end
  end

  # Save-as-new (Task 5.2): the rich-text editor's "Save as new version"
  # button. Always creates a fresh `origin: "manual"` row at the next version
  # number and makes it current immediately — mirrors how an AI-drafted
  # version becomes current on generation. Content is stored as HTML as-is
  # (see VersionableDocument-consuming models + _document_panel's render-side
  # HTML detection); no markdown conversion happens here.
  def create
    @idea = current_workshop_project.tasks.pipeline.find(params[:idea_id])

    if params[:kind] == "detail"
      new_draft = @idea.task_drafts.create!(source: TaskDraft::REFINE_SOURCE, origin: "manual",
                                            content: params[:content_html])
      new_draft.make_current!
      flash[:clar_toast] = "Saved as new version · now current"
      redirect_to workshop_idea_path(@idea, stage: "details", v: new_draft.version)
    else
      new_brief = @idea.briefs.create!(workspace: current_workspace, origin: "manual", status: "draft",
                                       version: Brief.next_version_for(@idea), content: params[:content_html])
      new_brief.make_current!
      flash[:clar_toast] = "Saved as new version · now current"
      redirect_to workshop_idea_path(@idea, stage: "briefing", v: new_brief.version)
    end
  end

  # Save-in-place (Task 5.2): the rich-text editor's "Save v{n} in place"
  # button. Updates the SAME row's content and stamps `edited_at` — origin,
  # version, and current-ness are all left untouched (a user-authored row
  # edited this way becomes "User description (edited)" via
  # VersionableDocument#label; other origins keep their existing label).
  def update
    @idea = current_workshop_project.tasks.pipeline.find(params[:idea_id])

    if params[:kind] == "detail"
      draft = @idea.task_drafts.by_source(TaskDraft::REFINE_SOURCE).find(params[:id])
      draft.update!(content: params[:content_html], edited_at: Time.current)
      redirect_to workshop_idea_path(@idea, stage: "details", v: draft.version)
      flash[:clar_toast] = "Saved v#{draft.version}"
    else
      brief = @idea.briefs.find(params[:id])
      brief.update!(content: params[:content_html], edited_at: Time.current)
      redirect_to workshop_idea_path(@idea, stage: "briefing", v: brief.version)
      flash[:clar_toast] = "Saved v#{brief.version}"
    end
  end

  private

  def make_current_brief(brief)
    brief.make_current!
    @idea.update!(description: JiraWriter.plain_text(brief.content))

    if @idea.external_reference.present?
      result = JiraClient.new.update_issue_description(
        issue_key: @idea.external_reference, description_text: JiraWriter.plain_text(brief.content)
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

  def make_current_draft(draft)
    draft.make_current!

    if @idea.external_reference.present?
      result = JiraClient.new.update_issue_description(
        issue_key: @idea.external_reference, description_text: JiraWriter.plain_text(draft.content)
      )
      unless result[:ok]
        flash[:clar_toast] = "v#{draft.version} set as current locally · Jira update failed: #{result[:error]}"
        redirect_to workshop_idea_path(@idea, stage: "details", v: draft.version) and return
      end
      flash[:clar_toast] = "v#{draft.version} set as current · Jira description updated"
    else
      flash[:clar_toast] = "v#{draft.version} set as current · local description updated"
    end

    redirect_to workshop_idea_path(@idea, stage: "details", v: draft.version)
  end
end
