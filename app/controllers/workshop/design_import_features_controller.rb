# What the person does with one feature on an import's page (Designs imports):
# Retry it (with words for the AI first, if they like), answer the AI's
# question (Send and continue), set it aside (Not needed), or decide on a
# proposal that would replace a thread's work (Accept, Reject, or words for a
# new one). Each queues the work and starts it, or lands it; the import's job
# builds what is queued one at a time. A re-import's features are fixed on
# its thread instead.
class Workshop::DesignImportFeaturesController < Workshop::BaseController
  before_action { require_permission!(:designs) }
  before_action { require_permission!(:configuration) }
  include DesignsVisibility
  before_action :load_feature

  def retry
    if @feature.problem || @feature.status == "set_aside"
      @feature.queue!(reply: params[:words])
      @import.start_work!
      flash[:clar_toast] = "Retrying #{@feature.name}"
    end
    back
  end

  def reply
    text = params[:reply].to_s.strip
    if @feature.problem == :waiting && text.present?
      @feature.queue!(reply: text, fresh: false)
      @import.start_work!
      flash[:clar_toast] = "Sent · #{@feature.name} goes on"
    end
    back
  end

  def set_aside
    @feature.update!(status: "set_aside", resets_at: nil) if @feature.problem && @feature.problem != :review
    back
  end

  # A proposal lands on master as it is. When master changed the same lines
  # meanwhile, it is brought up to date first, and lands after.
  def accept
    return back unless @feature.problem == :review

    Designs::ImportLanding.new(@feature).land!(accepted: true)
    @feature.update!(status: "done", finished_at: Time.current, branch: nil, review: @feature.review.merge("accepted" => true))
    flash[:clar_toast] = "Accepted · #{@feature.name} is on master"
    back
  rescue Designs::Repo::Conflict
    @feature.queue!(fresh: false)
    @feature.update!(review: @feature.review.merge("accepted" => true))
    @import.start_work!
    flash[:clar_toast] = "Master changed the same lines · bringing #{@feature.name} up to date first"
    back
  rescue Designs::ImportLanding::NotLanded => e
    flash[:clar_toast] = e.message
    back
  end

  # Master stays as it is, and the proposal goes.
  def reject
    return back unless @feature.problem == :review

    items = Array(@feature.review["comes_in"])
    Designs::ImportLanding.new(@feature).discard!
    @feature.update!(status: "set_aside", branch: nil,
                     review: @feature.review.merge("rejected" => "Rejected · not brought in#{": #{items.join('; ')}" if items.any?}".truncate(300)))
    back
  end

  # A new proposal, on the same branch, with the person's words.
  def revise
    words = params[:words].to_s.strip
    if @feature.problem == :review && words.present?
      @feature.queue!(reply: words, fresh: false)
      @import.start_work!
    end
    back
  end

  private

  def load_feature
    @import = current_workshop_project.design_setups.where.not(kind: "reimport").find(params[:design_import_id])
    @feature = @import.features.find(params[:id])
  end

  def back
    redirect_to helpers.import_page_path(@import)
  end
end
