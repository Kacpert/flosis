class Task < ApplicationRecord
  belongs_to :project
  has_many :time_entries, dependent: :nullify
  # nullify (not destroy): a bug's attribution is keyed by jira_key and must
  # survive the task's deletion (the bug lives on in delivered_issues). Without
  # this, deleting a Bug task that has an attribution would raise a FK violation.
  has_many :bug_attributions, dependent: :nullify
  has_many :chat_sessions, dependent: :destroy
  has_many :jira_comments, dependent: :destroy
  has_many :task_drafts, dependent: :destroy
  has_many :briefs, dependent: :destroy
  has_one :design_request, dependent: :destroy
  has_many_attached :attachments

  # The most recent AI-refined ticket description. Scoped to the "ai" source
  # so the refinement modal never receives breakdown JSON.
  def latest_draft
    task_drafts.by_source(TaskDraft::REFINE_SOURCE).newest_first.first
  end

  # The most recent estimate + sub-task breakdown (JSON).
  def latest_breakdown
    task_drafts.by_source(TaskDraft::BREAKDOWN_SOURCE).newest_first.first
  end

  # AI estimation total (points) for the Ready screen (Task 5.4). There is no
  # `ai_estimate_points` column yet (that lands in Phase 6) — until then this
  # falls back to the latest breakdown TaskDraft's JSON `total_points`.
  # Guards a missing breakdown and malformed/missing JSON, same rescue
  # pattern as JiraWriter#format_breakdown.
  def latest_breakdown_total_points
    breakdown = latest_breakdown
    return nil if breakdown.blank?

    data = JSON.parse(breakdown.content) rescue nil
    data && data["total_points"]
  end

  # The most recent brief (any status) for this task.
  def latest_brief
    briefs.newest_first.first
  end

  # The brief currently marked as current, falling back to the newest.
  def current_brief
    briefs.current.first || briefs.newest_first.first
  end

  # The AI-refined draft currently marked as current, falling back to the latest.
  def current_detail_draft
    task_drafts.by_source("ai").current.first || latest_draft
  end

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

  WORKSHOP_STAGES = %w[new briefing details ready].freeze
  enum :workshop_stage, WORKSHOP_STAGES.index_with(&:itself), prefix: :stage
  belongs_to :pipeline_author, class_name: "User", optional: true
  scope :pipeline, -> { where(in_pipeline: true).order(pipeline_entered_at: :desc) }
  scope :pipeline_active, -> { pipeline.where.not(workshop_stage: "ready") }

  def enter_pipeline!(author:, stage: "new")
    update!(in_pipeline: true, workshop_stage: stage,
            pipeline_entered_at: pipeline_entered_at || Time.current,
            pipeline_author: pipeline_author || author)
  end

  # A suggested (informational-only) branch name for the Ready screen (Task
  # 5.4). Nothing is created server-side — this is copy, not a git operation.
  def suggested_branch
    slug = name.parameterize[0, 32].delete_suffix("-")
    key  = external_reference&.downcase
    "feat/#{[key, slug].compact.join("-")}"
  end
end
