# Lands what was accepted on an import's page (Kacper, 2026-11-22: "czy
# możemy odpalać accept w tle … tak żeby ktoś mógł szybko zaakceptować zmiany
# a nie czekał"). Each Accept took 14–19 s in the request, so Accept now only
# marks the card landing (DesignSetupFeature#accept!) and enqueues this job.
# The job lands the import's accepted proposals one at a time, in the order
# they were accepted, through Designs::ImportLanding, as Accept did before:
# - one that lands is done;
# - one whose lines master changed meanwhile is queued for the import's job,
#   which brings it up to date first and lands it after;
# - one that cannot land goes back to its card, with the reason, to be
#   accepted again.
# The default queue's workers never run design turns, so a landing never
# waits behind an import building on the designs queue. It does share their
# three threads with the other default jobs, Claude's automations among them.
class Designs::ImportAcceptJob < ApplicationJob
  queue_as :default
  # One at a time per import: a second job waits in the queue without holding
  # a worker's thread, and lands what the first one left.
  limits_concurrency to: 1, key: ->(setup_id) { "designs-accept-#{setup_id}" }, duration: 10.minutes

  # A landing accepted longer ago than this and still landing lost its job:
  # a deploy cut it off.
  STALE = 5.minutes

  # Enqueued again, once per import, for every landing gone stale
  # (Designs::ResumeSetupsJob, every ten minutes). Running it again is safe: a
  # branch already on master lands nothing, and its feature is done.
  def self.resume!
    DesignSetupFeature.where(status: "landing", queued_at: ...STALE.ago).distinct.pluck(:design_setup_id).each { |id| perform_later(id) }
  end

  def perform(setup_id)
    tried = []
    while (feature = next_landing(setup_id, tried))
      tried << feature.id
      land(feature)
    end
  end

  private

  # The import's landing feature accepted first, of those this run has not
  # tried: each is tried once, whatever becomes of it.
  def next_landing(setup_id, tried)
    DesignSetupFeature.where(design_setup_id: setup_id, status: "landing").where.not(id: tried).order(:queued_at, :id).first
  end

  # A landing that finds nothing to merge was cut off after its push (a
  # deploy gives a job 5 s, a landing takes 14–19 s): master is on GitHub
  # already, and only its preview is left to publish.
  def land(feature)
    landing = Designs::ImportLanding.new(feature)
    landing.publish_master! unless landing.land!(accepted: true)
    feature.update!(status: "done", finished_at: Time.current, branch: nil, error: nil, review: feature.review.merge("accepted" => true))
  rescue Designs::Repo::Conflict
    feature.queue!(fresh: false)
    feature.update!(review: feature.review.merge("accepted" => true))
    feature.design_setup.start_work!
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] import #{feature.design_setup_id}, #{feature.key}: #{e.class}: #{e.message}")
    feature.update!(status: "review", error: not_landed(e))
  end

  # What the card says: GitHub's refusal as ImportLanding words it, or the
  # error's first line.
  def not_landed(error)
    return error.message if error.is_a?(Designs::ImportLanding::NotLanded)

    "Couldn't land on master: #{(error.message.presence || error.class.name).lines.first.to_s.strip.delete_suffix('.').truncate(300)}."
  end
end
