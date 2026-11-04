# Claude jobs make room while a Designs import runs (Designs imports). The
# host allows about 240 threads to everything the app runs, and an import's
# browser, its Claude and the browser's MCP server take most of them: on Nov 3
# other work failed to start ("can't create Thread"). While an import's unit
# runs, a Claude job that finds another one running that started before it
# comes back a few minutes later instead of starting a third Claude beside
# them; the first to start always goes, so they never all wait together.
#
# Alert rules and PR reviews do not wait: their dispatch keeps each to one
# run, and a run held back would be dispatched again and done twice.
module WaitsForDesignImport
  extend ActiveSupport::Concern

  JOBS = %w[AutoEstimateJob BugAttributionJob ProjectFeaturesScanJob BackfillDeliveredEstimatesJob].freeze
  WAIT = 3.minutes

  class << self
    # Test seam: how many of these jobs running now started before job.
    attr_writer :earlier_ai_jobs

    def earlier_ai_jobs
      @earlier_ai_jobs || lambda do |job|
        own = SolidQueue::ClaimedExecution.find_by(job_id: job.provider_job_id) or return 0
        SolidQueue::ClaimedExecution.joins(:job).where(solid_queue_jobs: { class_name: JOBS }).where(id: ...own.id).count
      end
    end
  end

  included do
    before_perform :wait_for_design_import
  end

  private

  def wait_for_design_import
    return unless DesignSetup.unit_running? && WaitsForDesignImport.earlier_ai_jobs.call(self).positive?

    retry_job(wait: WAIT)
    throw :abort
  end
end
