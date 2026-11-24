# Asks each integration whether it still works, and records the answer on the
# project so the topbar chips can tell the truth.
#
# A chip that goes green on "somebody filled this field in" is worse than no
# chip: a Figma token expired without a sound, and the first sign of it was the
# AI telling a client it couldn't open the design. Credentials rot on their own
# — tokens expire, get revoked, lose a scope — so something has to keep asking.
#
# GitHub keeps its existing per-poll check in PrReviewCheckJob (that one runs
# far more often); this fills it in too for projects where PR review is off.
class IntegrationHealthJob < ApplicationJob
  queue_as :default

  def perform
    Project.active.find_each do |project|
      IntegrationHealth::INTEGRATIONS.each { |integration| IntegrationHealth.check!(project, integration) }
    rescue StandardError => e
      # One broken project must not stop the rest from being checked.
      Rails.logger.error("[IntegrationHealthJob] project #{project.id} failed: #{e.message}")
    end
  end
end
