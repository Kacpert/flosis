# One change to a project's master (Workshop Designs v2), as Merge history
# lists it: a thread merged by a person ("manual"), by its task reaching Done
# ("auto"), or the setup's import ("setup"). The summary and what changed are
# written by Flosis AI after the merge (Designs::MergeSummaryJob).
class DesignMerge < ApplicationRecord
  HOWS = %w[manual auto setup].freeze

  belongs_to :project
  belongs_to :design_thread, optional: true
  belongs_to :task, optional: true
  belongs_to :user, optional: true

  validates :sha, :title, :branch, :merged_at, presence: true
  validates :how, inclusion: { in: HOWS }

  scope :newest_first, -> { order(merged_at: :desc, id: :desc) }

  # How it landed, in the design's words.
  def how_label
    case how
    when "manual" then "Manual · #{user&.name || 'someone'}"
    when "auto" then "Auto · #{task ? Designs::ThreadNames.key(task) : 'its task'} moved to Done"
    else "Flosis AI · setup"
    end
  end

  def short_sha = sha.to_s.first(7)
end
