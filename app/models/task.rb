class Task < ApplicationRecord
  belongs_to :project
  has_many :time_entries, dependent: :nullify
  has_many :chat_sessions, dependent: :destroy
  has_many_attached :attachments

  enum :status, { active: 0, done: 1 }

  # Where attachments are copied for Claude to read. The Jira issue key
  # (external_reference) gives each task its own folder.
  def attachments_disk_dir
    return nil if external_reference.blank?
    base = ENV.fetch("TASK_ATTACHMENTS_DIR", File.expand_path("~/work/elvium/.task-attachments"))
    File.join(base, external_reference)
  end

  scope :jira_synced, -> { where(external_type: "jira") }
  scope :local_only, -> { where(external_type: [nil, ""]) }

  validates :name, presence: true, uniqueness: { scope: :project_id }
end
