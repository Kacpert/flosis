# Claude jobs make room while a Designs import runs (Designs imports). The
# host allows about 240 threads to everything the app runs, and an import's
# browser, its Claude and the browser's MCP server take most of them: on Nov 3
# other work failed to start ("can't create Thread"). While an import's unit
# runs, a Claude job that finds another Claude job already running comes back
# a few minutes later instead of starting a third Claude beside them.
module WaitsForDesignImport
  extend ActiveSupport::Concern

  JOBS = %w[AutoEstimateJob AlertRuleRunJob PrReviewJob BugAttributionJob ProjectFeaturesScanJob BackfillDeliveredEstimatesJob].freeze
  WAIT = 3.minutes

  class << self
    # Test seam: how many Claude jobs run now, the asking one included.
    attr_writer :running_ai_jobs

    def running_ai_jobs
      @running_ai_jobs || -> { SolidQueue::ClaimedExecution.joins(:job).where(solid_queue_jobs: { class_name: JOBS }).count }
    end
  end

  included do
    before_perform :wait_for_design_import
  end

  private

  def wait_for_design_import
    return unless DesignSetup.unit_running? && WaitsForDesignImport.running_ai_jobs.call > 1

    retry_job(wait: WAIT)
    throw :abort
  end
end
