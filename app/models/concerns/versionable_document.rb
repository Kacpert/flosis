module VersionableDocument
  extend ActiveSupport::Concern

  included do
    scope :current, -> { where(current: true) }
    validates :origin, inclusion: { in: %w[user ai manual] }
  end

  def label
    case origin
    when "user"   then edited_at? ? "User description (edited)" : "User description"
    when "manual" then "Manual edit"
    else "AI drafted"
    end
  end

  def make_current!
    transaction do
      siblings_scope.update_all(current: false)
      update!(current: true)
    end
  end
end
