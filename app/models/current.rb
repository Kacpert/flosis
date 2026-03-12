class Current < ActiveSupport::CurrentAttributes
  attribute :session, :workspace
  delegate :user, to: :session, allow_nil: true
end
