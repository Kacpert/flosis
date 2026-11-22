# A run that came back with no cost stays flagged to Flosis staff until
# somebody has looked at it (SCRUM-70). It is never counted as $0 either way.
class Hidmin::AiRunsController < Hidmin::BaseController
  def looked_at
    run = AiRun.find(params[:id])
    run.update!(unknown_reviewed_at: Time.current, unknown_reviewed_by: current_user)
    redirect_to hidmin_workspace_path(run.workspace_id), flash: { clar_toast: "Marked as looked at" }
  end
end
