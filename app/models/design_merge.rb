# One change to a project's master (Workshop Designs v2), as Merge history
# lists it: a thread merged by a person ("manual"), by its task reaching Done
# ("auto"), the setup's import ("setup"), or one feature of an import landing by
# itself after it ("import"). The summary is the thread's last
# reply, and what changed is what people asked for (Designs::Threads.merge!).
#
# A thread's merge is also its acceptance (2026-11-21): slot names the preview
# copy of the merge commit (accepted/<thread id>), and a task's merge records
# the description version it wrote and when the task's page announced it.
class DesignMerge < ApplicationRecord
  HOWS = %w[manual auto setup import].freeze

  belongs_to :project
  belongs_to :design_thread, optional: true
  belongs_to :task, optional: true
  belongs_to :user, optional: true

  # Declared :json, as MariaDB would type the columns :text (see
  # DesignRequest#links).
  attribute :screens, :json, default: []
  attribute :what_changed, :json, default: []
  # What the task's description version written from it changed (Designs::
  # DescribeJob), as up to three short lines for the task's modal.
  attribute :description_changes, :json, default: []

  validates :sha, :title, :branch, :merged_at, presence: true
  validates :how, inclusion: { in: HOWS }

  scope :newest_first, -> { order(merged_at: :desc, id: :desc) }

  # How it landed, in the design's words.
  def how_label
    case how
    when "manual" then "Manual · #{user&.name || 'someone'}"
    when "auto" then "Auto · #{task ? Designs::ThreadNames.key(task) : 'its task'} moved to Done"
    when "import" then "Flosis AI · import"
    else "Flosis AI · setup"
    end
  end

  def short_sha = sha.to_s.first(7)
end
