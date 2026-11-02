# The AI estimation settings, shared while they live on both the workspace and
# the project. MySQL (prod) doesn't support JSON column defaults, so the
# ["AI estimation"] default lives here instead of in the migration (dev/test =
# PostgreSQL, prod = MySQL).
#
# MySQL also hands a :json column back as a raw JSON *string* in some cases
# (PostgreSQL parses it to an Array). Normalizing in one place keeps the two
# models from disagreeing about what "no fields chosen" means — the views
# ("names - ESTIMATION_FIELD_OPTIONS", "names.each") 500 on a String or a nil.
module EstimationSettings
  extend ActiveSupport::Concern

  DEFAULT_ESTIMATION_FIELD_NAME = "AI estimation".freeze

  # Configuration -> AI tab: the built-in Jira field-name choices offered as
  # chips. A project may also have a custom (free-added) field name stored in
  # estimation_field_names that isn't in this list — the view renders those as
  # extra pre-checked chips alongside these options.
  ESTIMATION_FIELD_OPTIONS = [
    "AI estimation",
    "Story point estimate",
    "T-shirt size",
    "Confidence (1–5)"
  ].freeze

  ESTIMATION_TRIGGERS = {
    "sprint" => "Added to a Development sprint",
    "status" => "Status changes to “Ready for dev”",
    "briefed" => "AI actions = Briefed",
    "manual" => "Manually, on request"
  }.freeze

  def estimation_field_names
    normalize_field_names(super)
  end

  def estimation_trigger_label
    ESTIMATION_TRIGGERS[estimation_trigger] || estimation_trigger
  end

  private

  def normalize_field_names(value)
    if value.is_a?(String)
      value = value.blank? ? nil : (JSON.parse(value) rescue value)
    end
    array = Array(value).reject { |v| v.nil? || v == "" }
    array.presence || [ DEFAULT_ESTIMATION_FIELD_NAME ]
  end
end
