require "test_helper"

# Claude jobs make room while a Designs import runs (Designs imports): the
# host allows about 240 threads to all the app runs, and an import's browser,
# Claude and MCP server take most of them. Only one waits for another that
# started before it, so they never all wait together; alert rules and PR
# reviews, which their own dispatch keeps to one run, never wait.
class WaitsForDesignImportTest < ActiveJob::TestCase
  class AiJob < ApplicationJob
    include WaitsForDesignImport
    cattr_accessor :ran, default: 0

    def perform = self.class.ran += 1
  end

  teardown do
    WaitsForDesignImport.earlier_ai_jobs = nil
    AiJob.ran = 0
  end

  def import_unit_runs
    projects(:jira_project).design_setups.create!(status: "active", unit_job_id: "busy", unit_deadline_at: 10.minutes.from_now)
  end

  test "an AI job waits while an import unit runs and an AI job that started before it is running" do
    import_unit_runs
    WaitsForDesignImport.earlier_ai_jobs = ->(_job) { 1 }
    AiJob.perform_now
    assert_equal 0, AiJob.ran
    assert_enqueued_jobs 1, only: AiJob
  end

  test "it goes ahead beside an import when no AI job started before it" do
    import_unit_runs
    WaitsForDesignImport.earlier_ai_jobs = ->(_job) { 0 }
    AiJob.perform_now
    assert_equal 1, AiJob.ran
  end

  test "it runs at once when no import runs" do
    WaitsForDesignImport.earlier_ai_jobs = ->(_job) { flunk "nothing to count without an import" }
    projects(:jira_project).design_setups.create!(status: "active", paused_until: 1.hour.from_now, unit_deadline_at: 2.hours.from_now)
    AiJob.perform_now
    assert_equal 1, AiJob.ran
  end

  test "the background Claude jobs wait for an import, alert rules and PR reviews do not" do
    [ AutoEstimateJob, BugAttributionJob, ProjectFeaturesScanJob, BackfillDeliveredEstimatesJob ].each do |job|
      assert_includes job.ancestors, WaitsForDesignImport, job.name
    end
    [ AlertRuleRunJob, PrReviewJob ].each { |job| assert_not_includes job.ancestors, WaitsForDesignImport, job.name }
  end
end
