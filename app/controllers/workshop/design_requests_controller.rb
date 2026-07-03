# The designs strip on an idea's workspace (details + ready stages) — request
# designs from a team member, mark delivered with Figma links (synced into the
# Jira description), cancel, or request changes. One row per task (has_one,
# unique index) — "request changes" transitions the SAME row back to
# "requested" rather than creating a new one, so link history survives.
class Workshop::DesignRequestsController < Workshop::BaseController
  def create
    @idea = current_workshop_project.tasks.pipeline.find(params[:idea_id])
    designer = User.find(create_params[:designer_id])

    @idea.create_design_request!(requester: current_user, designer: designer, note: create_params[:note])

    flash[:clar_toast] = "Design request sent to #{designer.name}"
    redirect_to workshop_idea_path(@idea, stage: @idea.workshop_stage)
  end

  # kind=deliver: marks delivered, storing normalized link rows, and syncs the
  # Jira description. kind=request_changes: sends the SAME row back to
  # "requested" (designer may be swapped, note updated), keeping links intact.
  def update
    @idea = current_workshop_project.tasks.pipeline.find(params[:idea_id])
    design_request = @idea.design_request

    if params[:kind] == "request_changes"
      designer_id = update_params[:designer_id]
      designer = designer_id.present? ? User.find(designer_id) : nil
      design_request.request_changes!(designer: designer, note: update_params[:note])

      sync_result = JiraWriter.new(workspace: current_workspace).sync_design_links(@idea, design_request.links)
      flash[:clar_toast] = if sync_result[:ok]
        "Design request changes requested"
      else
        "Design request changes requested · Jira sync failed: #{sync_result[:error]}"
      end
    else
      links = normalize_links(update_params[:links])
      design_request.deliver!(links)

      sync_result = JiraWriter.new(workspace: current_workspace).sync_design_links(@idea, links)
      flash[:clar_toast] = if sync_result[:ok]
        "Designs delivered · #{links.size} link#{"s" unless links.size == 1} added to Jira description"
      else
        "Designs delivered locally · Jira sync failed: #{sync_result[:error]}"
      end
    end

    redirect_to workshop_idea_path(@idea, stage: @idea.workshop_stage)
  end

  # Cancels the request (mockup: "Cancel" from the "requested" state).
  def destroy
    @idea = current_workshop_project.tasks.pipeline.find(params[:idea_id])
    @idea.design_request.cancel!

    flash[:clar_toast] = "Design request cancelled"
    redirect_to workshop_idea_path(@idea, stage: @idea.workshop_stage)
  end

  private

  # Blank name rows auto-fill as "Figma frame {n}" (1-indexed by position in
  # the submitted list) and blank-url rows are dropped entirely — this is how
  # "remove" (mockup line 808) is expressed: the row is simply omitted from
  # the resubmitted list, so an empty list here means "remove the last link".
  def normalize_links(raw)
    Array(raw).each_with_index.filter_map do |row, i|
      url = row[:url].to_s.strip
      next if url.blank?
      name = row[:name].to_s.strip
      name = "Figma frame #{i + 1}" if name.blank?
      { "name" => name, "url" => url }
    end
  end

  def create_params
    params.require(:design_request).permit(:designer_id, :note)
  end

  def update_params
    params.require(:design_request).permit(:designer_id, :note, links: [:name, :url])
  end
end
