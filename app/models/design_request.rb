# One design request per task (unique index on task_id — see the migration).
# "Request changes" does not create a new row: it transitions the SAME record's
# status back to "requested", preserving links/history/note so the Jira
# description sync (JiraWriter#sync_design_links) always reflects the current
# link set rather than losing prior context.
class DesignRequest < ApplicationRecord
  belongs_to :task
  belongs_to :requester, class_name: "User"
  belongs_to :designer, class_name: "User"

  # MySQL JSON columns cannot carry a DB default (unlike Postgres jsonb), so
  # the [] default lives here instead of the migration — keeps dev/test
  # (Postgres) and prod (MySQL) behaving identically.
  attribute :links, default: []

  STATUSES = %w[requested delivered cancelled].freeze
  validates :status, inclusion: { in: STATUSES }
  validates :task_id, uniqueness: true

  STATUSES.each do |s|
    define_method("#{s}?") { status == s }
  end

  # Marks delivered: stores the link rows and stamps delivered_at. `links` is
  # an array of { "name" => ..., "url" => ... } hashes (already normalized by
  # the controller — blank names auto-filled as "Figma frame {n}").
  def deliver!(links)
    update!(status: "delivered", links: links, delivered_at: Time.current)
  end

  def cancel!
    update!(status: "cancelled")
  end

  # Sends the SAME request back to "requested" — the designer may be swapped
  # and/or the note updated, but links (the delivery history) are kept as-is.
  def request_changes!(designer: nil, note: nil)
    attrs = { status: "requested" }
    attrs[:designer] = designer if designer.present?
    attrs[:note] = note if note.present?
    update!(attrs)
  end
end
