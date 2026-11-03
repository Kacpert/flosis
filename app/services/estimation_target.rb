# What Configuration's Estimation target card offers, read from the project's
# Jira instead of the first customer's: the boards the sync keeps, the
# statuses on them, and the number fields an estimate can be written to.
class EstimationTarget
  FIELDS_CACHED_FOR = 10.minutes

  def initialize(project)
    @project = project
  end

  def board_name
    @project.jira_boards.order(:name).pluck(:name).join(", ").presence || @project.name
  end

  # In board-column order, each status once.
  def statuses
    JiraBoardColumnStatus.joins(jira_board_column: :jira_board)
                         .where(jira_boards: { project_id: @project.id })
                         .order("jira_boards.id", "jira_board_columns.position", "jira_board_column_statuses.id")
                         .pluck(:jira_status_name).uniq
  end

  # The number fields on the project's own Jira site, or nil. A project on the
  # server's Jira keeps EstimationSettings::ESTIMATION_FIELD_OPTIONS — that
  # Jira's fields — and a Jira that can't be read offers nothing new.
  def field_names
    credentials = ProjectCredentials.new(@project)
    return nil unless credentials.own_jira_site? && credentials.jira_configured?

    Rails.cache.fetch([ "estimation-fields", @project.id, credentials.jira_site, @project.external_reference ],
                      expires_in: FIELDS_CACHED_FOR, skip_nil: true) do
      JiraClient.for(@project).fetch_number_fields(@project.external_reference)
    end
  rescue StandardError => e
    # The Configuration page must open while Jira is down or the URL is bad.
    Rails.logger.warn("[EstimationTarget] project #{@project.id}: #{e.class}: #{e.message}")
    nil
  end
end
