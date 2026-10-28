# Creates a project and settles, in one place, the two things the new-project
# dialog decides: which credentials it starts with, and who is in it.
#
# Credentials are COPIED from the chosen source rather than referenced. A
# reference would make rotating a key a one-move job, but it would also make
# deleting a project a question about other projects' keys, and there is no
# good answer to that question at three in the morning.
class ProjectCreator
  # Which columns each integration owns. The repository is deliberately absent
  # from :github — the dialog asks for it directly, and what the person typed
  # must beat what was copied.
  #
  # The three cached Jira field ids travel with the Jira credentials: they are a
  # property of the SITE, so the project that reuses the site already knows
  # them, and leaving them blank means AI estimation and story-point mirroring
  # are unconfigured until someone presses "Verify fields".
  CREDENTIALS = {
    "jira" => %i[jira_site jira_email jira_api_token jira_story_points_field_id
                 jira_ai_estimation_field_id jira_ai_actions_field_id],
    "github" => %i[github_token],
    "figma" => %i[figma_token figma_read_enabled],
    "ai" => %i[anthropic_api_key]
  }.freeze

  # The one column per integration whose absence means "Reuse key from X" would
  # copy nothing. ProjectCredentials falls back to the machine's environment and
  # to the Claude CLI's own login, so a project can work perfectly while holding
  # no key of its own — and offering it as a source copies blanks in silence.
  # `figma_read_enabled` is deliberately not here: it is a switch, not a key.
  KEY_COLUMNS = {
    "jira" => :jira_api_token,
    "github" => :github_token,
    "figma" => :figma_token,
    "ai" => :anthropic_api_key
  }.freeze

  # Whether this project has anything to lend for this integration. Discord
  # owns no column at all — its webhooks are rows added afterwards from
  # Configuration — so it answers false for everyone.
  def self.reusable?(project, integration)
    column = KEY_COLUMNS[integration.to_s]
    column.present? && project[column].present?
  end

  def initialize(workspace:, attributes:, reuse_from: {}, member_ids: [], preset: PermissionPreset::LEAST_PRIVILEGED)
    @workspace = workspace
    @attributes = attributes
    @reuse_from = reuse_from || {}
    @member_ids = Array(member_ids)
    @preset = preset
  end

  def call
    project = @workspace.projects.new(@attributes)
    # `color` carries a database default, so it is never blank on a new record
    # and `||=` would never fire — what decides this is whether the caller
    # named a colour, not what the column happens to hold.
    project.color = next_colour if @attributes[:color].blank?
    copy_credentials_into(project)
    # `external_type: "jira"` is what `jira_connected?` answers, and it decides
    # whether the Jira chip claims a connection, whether the health check calls
    # Jira for this project, and whether the daily features scan writes a
    # codebase summary onto it. So it is set only when the dialog actually gave
    # the project Jira credentials — never as a default for every new project.
    #
    # And only with a project key as well. Credentials without a key sync
    # nothing (JiraSyncService has no board to ask about) while the health check
    # still succeeds, so the chip would go green on a project that can never
    # return a ticket.
    project.external_type = "jira" if project.jira_site.present? && project.external_reference.present?

    # The column defaults to false, because most projects are born in Time & HR
    # as somewhere for hours to land. This one was created from the Flosis
    # dialog, so it is a Workshop project by definition — without this it would
    # vanish from the switcher the moment it was created. An explicit attribute
    # still wins, so a caller can create a hidden project on purpose.
    project.show_in_workshop = true unless @attributes.key?(:show_in_workshop) ||
                                           @attributes.key?("show_in_workshop")

    # One transaction: a membership that cannot be saved used to leave the
    # project behind while the caller was told the create had failed.
    @workspace.transaction do
      project.save!
      add_members(project)
    end
    project
  end

  private

  # `color` is validated present and hex-formatted, and the dialog does not ask
  # for one — so the service takes the first swatch the workspace is not already
  # using, and cycles once every swatch is taken.
  def next_colour
    taken = @workspace.projects.pluck(:color)
    Project::PROJECT_COLORS.find { |colour| taken.exclude?(colour) } ||
      Project::PROJECT_COLORS[@workspace.projects.count % Project::PROJECT_COLORS.size]
  end

  def copy_credentials_into(project)
    CREDENTIALS.each do |integration, columns|
      source = source_for(integration)
      next unless source

      columns.each do |column|
        # Never overwrite what the dialog collected.
        project[column] = source[column] if project[column].blank?
      end
    end
  end

  # Only a project in the SAME workspace may be a source. Anything else would
  # be one workspace reading another's secrets through a guessed id.
  def source_for(integration)
    id = @reuse_from[integration].presence
    return nil unless id

    @workspace.projects.find_by(id: id)
  end

  # Scoped to the workspace, so a guessed id cannot pull a stranger's account
  # onto the project, and run through the same refusal the Users grid makes —
  # see ProjectMembership.grantable for why an administrator must not hold a
  # row here.
  def add_members(project)
    users = ProjectMembership.grantable(
      User.where(id: @member_ids)
          .joins(:workspace_memberships)
          .where(workspace_memberships: { workspace_id: @workspace.id }),
      @workspace
    )

    users.find_each do |user|
      project.project_memberships.build(user: user).apply_preset(@preset).save!
    end
  end
end
