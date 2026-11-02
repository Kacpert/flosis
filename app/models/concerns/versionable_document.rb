module VersionableDocument
  extend ActiveSupport::Concern

  included do
    scope :current, -> { where(current: true) }
    validates :origin, inclusion: { in: %w[user jira ai manual] }
  end

  # "jira" is a v0 seeded straight from the ticket's own description — calling
  # that "User description" was wrong: nobody here wrote it, Jira did.
  def label
    case origin
    when "user"   then edited_at? ? "User description (edited)" : "User description"
    when "jira"   then edited_at? ? "Jira description (edited)" : "Jira description"
    when "manual" then "Manual edit"
    else "AI drafted"
    end
  end

  # Human source material (typed here or pulled from the ticket) as opposed to
  # something the AI drafted — drives the panel's badge colour and the editor
  # hint, which treat both the same way.
  def source_document?
    %w[user jira].include?(origin)
  end

  def make_current!
    transaction do
      siblings_scope.update_all(current: false)
      update!(current: true)
    end
  end
end
