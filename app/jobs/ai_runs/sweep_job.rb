# A run whose job died with it (a deploy restarts SolidQueue mid-run) never
# finishes its row, which would stay "running" and out of every total. Past
# AiRun::STALE_AFTER it is failed, its cost unknown: the tokens it used were
# spent, but nothing reported them.
class AiRuns::SweepJob < ApplicationJob
  queue_as :default

  def perform
    AiRun.where(status: "running").where(ran_at: ...AiRun::STALE_AFTER.ago)
         .update_all(status: "failed", cost_usd: nil, price_usd: nil, updated_at: Time.current)
  end
end
