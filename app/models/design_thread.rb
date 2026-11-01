# A design thread (Workshop Designs v2): a branch of the project's design repo,
# made from master, and the conversation with Flosis AI that changes it. It is
# open until it is merged into master, by hand or when its task is Done, and
# read-only after that.
#
# A thread is fresh until its first message names its branch
# (Designs::ThreadNames). It remembers the master commit it is based on
# (base_sha), so it knows which merges landed since, and the task description
# it last designed from (described_text, described_version), so it knows when
# the description moved on.
class DesignThread < ApplicationRecord
  STATUSES = %w[open merged].freeze

  belongs_to :project
  belongs_to :task, optional: true
  belongs_to :author, class_name: "User", optional: true
  belongs_to :chat_session, optional: true
  has_many :design_merges, dependent: :nullify

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :task_id, uniqueness: true, allow_nil: true
  validates :branch, uniqueness: { scope: :project_id }, allow_nil: true

  scope :open, -> { where(status: "open") }
  scope :merged, -> { where(status: "merged") }

  def open? = status == "open"
  def merged? = status == "merged"
  def fresh? = branch.blank?
end
