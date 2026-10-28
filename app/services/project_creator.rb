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
  CREDENTIALS = {
    "jira" => %i[jira_site jira_email jira_api_token],
    "github" => %i[github_token],
    "figma" => %i[figma_token figma_read_enabled],
    "ai" => %i[anthropic_api_key]
  }.freeze

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
    project.external_type = "jira" if project.jira_site.present?

    project.save!
    add_members(project)
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
  # onto the project.
  def add_members(project)
    users = User.where(id: @member_ids)
                .joins(:workspace_memberships)
                .where(workspace_memberships: { workspace_id: @workspace.id })

    users.find_each do |user|
      project.project_memberships.build(user: user).apply_preset(@preset).save!
    end
  end
end
