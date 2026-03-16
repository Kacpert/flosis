class JiraSyncService
  def initialize(project, client: nil)
    @project = project
    @client = client || JiraClient.new
  end

  def sync
    return unless @project.jira_connected?

    sync_boards
    sync_issues
    sync_sprint_assignments
  end

  private

  def sync_boards
    boards_data = @client.fetch_boards(@project.external_reference)
    return if boards_data.nil?

    status_names = @client.fetch_statuses
    synced_board_ids = []

    boards_data.each do |board_data|
      board = @project.jira_boards.find_or_initialize_by(jira_board_id: board_data[:id])
      board.update!(name: board_data[:name], board_type: board_data[:type])
      synced_board_ids << board.id

      sync_board_columns(board, board_data[:id], status_names)
      sync_sprints(board, board_data[:id])
    end

    @project.jira_boards.where.not(id: synced_board_ids).destroy_all
  end

  def sync_board_columns(board, jira_board_id, status_names)
    columns_data = @client.fetch_board_configuration(jira_board_id)
    return if columns_data.nil?

    synced_column_ids = []

    columns_data.each_with_index do |col_data, position|
      column = board.jira_board_columns.find_or_initialize_by(position: position)
      column.update!(name: col_data[:name])
      synced_column_ids << column.id

      sync_column_statuses(column, col_data[:statuses], status_names)
    end

    board.jira_board_columns.where.not(id: synced_column_ids).destroy_all
  end

  def sync_column_statuses(column, statuses_data, status_names)
    return if statuses_data.nil?

    synced_status_ids = []

    statuses_data.each do |status_data|
      status = column.jira_board_column_statuses.find_or_initialize_by(jira_status_id: status_data[:id])
      resolved_name = status_names[status_data[:id].to_s] || "Unknown"
      status.update!(jira_status_name: resolved_name)
      synced_status_ids << status.id
    end

    column.jira_board_column_statuses.where.not(id: synced_status_ids).destroy_all
  end

  def sync_sprints(board, jira_board_id)
    sprints_data = @client.fetch_sprints(jira_board_id)
    return if sprints_data.nil?

    synced_sprint_ids = []

    sprints_data.each do |sprint_data|
      sprint = board.jira_sprints.find_or_initialize_by(jira_sprint_id: sprint_data[:id])
      sprint.update!(
        name: sprint_data[:name],
        state: sprint_data[:state],
        start_date: sprint_data[:start_date],
        end_date: sprint_data[:end_date]
      )
      synced_sprint_ids << sprint.id
    end

    board.jira_sprints.where.not(id: synced_sprint_ids).destroy_all
  end

  def sync_sprint_assignments
    # Clear all sprint assignments first, then reassign from active/future sprints
    @project.tasks.jira_synced.where.not(sprint_id: nil).update_all(sprint_id: nil, sprint_name: nil)

    @project.jira_boards.each do |board|
      board.jira_sprints.where(state: %w[active future]).find_each do |sprint|
        issue_keys = @client.fetch_sprint_issue_keys(sprint.jira_sprint_id)
        next if issue_keys.empty?

        @project.tasks.jira_synced
          .where(external_reference: issue_keys)
          .update_all(sprint_id: sprint.jira_sprint_id, sprint_name: sprint.name)
      end
    end
  end

  def sync_issues
    issues = @client.fetch_issues(@project.external_reference)
    return if issues.nil?

    issues.each do |issue|
      sync_issue(issue)
    end
  end

  def sync_issue(issue)
    task = @project.tasks.find_or_initialize_by(
      external_reference: issue[:key],
      external_type: "jira"
    )

    name = build_name(issue[:key], issue[:summary])

    task.assign_attributes(
      name: name,
      external_url: issue[:url],
      assignee_email: issue[:assignee_email],
      assignee_name: issue[:assignee_name],
      jira_status_name: issue[:status_name],
      status: map_status(issue[:status_category]),
      description: issue[:description],
      description_adf: issue[:description_adf],
      priority: issue[:priority],
      issue_type: issue[:issue_type],
      labels: issue[:labels]&.to_json,
      reporter_email: issue[:reporter_email],
      reporter_name: issue[:reporter_name],
      sprint_id: issue[:sprint_id],
      sprint_name: issue[:sprint_name],
      time_estimate_seconds: issue[:time_estimate_seconds]
    )

    ActiveRecord::Base.transaction(requires_new: true) do
      task.save!
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    task.name = "#{issue[:key]} #{issue[:summary]} [#{issue[:key]}]"
    ActiveRecord::Base.transaction(requires_new: true) { task.save! }
  rescue StandardError => e
    Rails.logger.warn("[JiraSyncService] Failed to sync #{issue[:key]}: #{e.message}")
  end

  def build_name(key, summary)
    "#{key} #{summary}"
  end

  def map_status(status_category)
    case status_category
    when "done" then :done
    else :active
    end
  end
end
