class JiraSyncJob < ApplicationJob
  queue_as :default

  def perform
    Project.where(external_type: "jira").find_each do |project|
      JiraSyncService.new(project).sync
    rescue => e
      Rails.logger.error("[JiraSyncJob] Failed to sync project #{project.id}: #{e.message}")
    end
  end
end
