require "test_helper"

# Solid Queue runs a job only on a worker that serves its queue. A queue no
# worker serves just fills up, with no error anywhere. Ruling P2-R20.
class QueueConfigTest < ActiveSupport::TestCase
  ENVIRONMENTS = %w[development test production].freeze

  # Read as Solid Queue reads it: ERB first, then YAML with its aliases.
  def workers(env)
    ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/queue.yml"))
                                    .deep_symbolize_keys.fetch(env.to_sym).fetch(:workers)
  end

  # Solid Queue's reading of a worker's queues: "*" is every queue, a name
  # ending in * a prefix, anything else one queue by its name. A worker that
  # names none serves every queue.
  def serves?(worker, queue)
    Array(worker.fetch(:queues, "*")).map(&:to_s).any? do |name|
      name == "*" || name == queue || (name.end_with?("*") && queue.start_with?(name.delete_suffix("*")))
    end
  end

  # Every app job's queue, each mailer's delivery queue, and the queue the
  # recurring command tasks (clear_solid_queue_finished_jobs) run on.
  def queues_in_use
    Rails.application.eager_load!
    jobs = ApplicationJob.descendants.map { |job| job.new.queue_name }
    mail = ActionMailer::Base.descendants.map do |mailer|
      mailer.delivery_job.new(mailer.name, "mail", "deliver_now", args: []).queue_name
    end
    (jobs + mail + [ SolidQueue::RecurringJob.queue_name ]).uniq
  end

  test "every queue a job is put on has a worker, in every environment" do
    queues = queues_in_use
    assert_includes queues, "designs"
    assert_includes queues, "solid_queue_recurring"
    ENVIRONMENTS.each do |env|
      queues.each { |queue| assert workers(env).any? { |worker| serves?(worker, queue) }, "#{env}: no worker serves #{queue}" }
    end
  end

  # A deleted design thread waits DesignThread::KEPT under Deleted; a nightly
  # run takes the ones past it for good.
  test "deleted design threads past their 20 days go every night in production" do
    tasks = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).deep_symbolize_keys.fetch(:production)
    purge = tasks.values.find { |task| task[:class] == "Designs::PurgeDeletedThreadsJob" }
    assert purge, "no recurring task runs Designs::PurgeDeletedThreadsJob"
    assert_equal "30 4 * * *", purge[:schedule]
  end

  # A design turn runs for minutes. On the general worker it would hold one
  # of the threads every other job runs on.
  test "design turns run on a worker of their own and nowhere else" do
    ENVIRONMENTS.each do |env|
      serving = workers(env).select { |worker| serves?(worker, "designs") }
      assert_equal [ [ "designs" ] ], serving.map { |worker| Array(worker[:queues]) }, env
    end
  end
end
