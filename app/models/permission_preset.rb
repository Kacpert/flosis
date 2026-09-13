# The six things a person can be allowed to do inside a project, plus the
# handful of named combinations worth a button in the invite dialog.
#
# A role is NOT stored anywhere. The switches are the truth and the name is
# read back off them, so flipping one switch simply moves the label — possibly
# to "Custom", which is a legitimate state rather than an error.
module PermissionPreset
  # Interface order, used by every view that renders the switches. Briefing
  # Configuration precedes Configuration.
  PERMISSIONS = %i[automations tasks reporting pricing briefing_config configuration].freeze

  # Pricing is deliberately off by default. Reporting is on by default, so
  # folding the two together would show every Project Manager the team's rates.
  PRESETS = {
    "Project Manager" => %i[automations tasks reporting].freeze,
    "Product Owner" => %i[automations tasks reporting briefing_config].freeze,
    "Administrator" => PERMISSIONS
  }.freeze

  CUSTOM = "Custom".freeze
  LEAST_PRIVILEGED = "Project Manager".freeze

  # The name for a granted set, or "Custom" when it matches no preset. Callers
  # pass whatever order and type they happen to have.
  def self.label_for(granted)
    wanted = Array(granted).map(&:to_sym).uniq.sort
    PRESETS.each { |label, permissions| return label if permissions.sort == wanted }
    CUSTOM
  end

  # A preset as a full hash of switches, ready for assign_attributes. Every one
  # of the six keys is present, so applying a preset also turns things OFF.
  def self.attributes_for(label)
    permissions = PRESETS.fetch(label.to_s, PRESETS[LEAST_PRIVILEGED])
    PERMISSIONS.index_with { |permission| permissions.include?(permission) }
  end
end
