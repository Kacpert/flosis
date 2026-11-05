# Takes deleted design threads for good once they have waited
# DesignThread::KEPT under Deleted (Designs::Threads.delete!): their archive
# branch on GitHub, then the thread with its conversation. A thread whose
# archive GitHub keeps is tried again the next day.
class Designs::PurgeDeletedThreadsJob < ApplicationJob
  queue_as :default

  def perform
    DesignThread.deleted.where(deleted_at: ...DesignThread::KEPT.ago).find_each do |thread|
      Designs::Threads.purge!(thread)
    rescue StandardError => e
      Rails.logger.error("[#{self.class.name}] thread #{thread.id}: #{e.class}: #{e.message}")
    end
  end
end
