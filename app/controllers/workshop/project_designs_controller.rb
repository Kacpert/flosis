# The Designs page of the Workshop's current project, from the sidebar: the
# project's whole design (master), sandboxed under a grant, with its lasting
# link, and the design conversations of its tasks, each opening that task's
# Designs screen. A project with no designs yet says what is missing.
class Workshop::ProjectDesignsController < Workshop::BaseController
  before_action { require_permission!(:tasks) }

  def show
    @project = current_workshop_project
    return unless @project&.designs_ready?

    publisher = Designs::Publisher.new(@project, nil)
    if publisher.published?(Designs::Repo::MASTER)
      @master_preview = publisher.grant_url(Designs::Repo::MASTER)
      @master_link = publisher.url(Designs::Repo::MASTER)
    end
    @conversations = @project.tasks.pipeline
                             .where(id: ChatSession.active.where(purpose: "designs").select(:task_id))
                             .order(updated_at: :desc)
  end
end
