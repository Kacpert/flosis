class Workshop::JiraBrowserController < Workshop::BaseController
  # Renders the turbo-frame content for the "Browse Jira boards" modal:
  # board tabs (each synced JiraBoard + a synthetic "Backlog" tab), a kanban
  # view (board columns -> statuses -> tasks) or, for Backlog, a grooming
  # table (tasks with no sprint). Mirrors the grouping approach from
  # JiraTasksController#board_data.
  BACKLOG_BOARD_ID = "backlog".freeze

  PRIORITY_ORDER_SQL = "CASE tasks.priority WHEN 'High' THEN 0 WHEN 'Medium' THEN 1 WHEN 'Low' THEN 2 ELSE 3 END".freeze
  POINTS_ORDER_SQL = "CASE WHEN tasks.story_points IS NULL THEN 1 ELSE 0 END, tasks.story_points DESC".freeze
  DATE_COALESCE_SQL = "COALESCE(tasks.jira_created_at, tasks.created_at)".freeze

  helper_method :backlog_selected?

  def show
    @boards = current_workshop_project ? current_workshop_project.jira_boards.order(:name) : JiraBoard.none
    @selected_board_id = params[:board].presence || @boards.first&.id&.to_s || BACKLOG_BOARD_ID
    # Which pipeline stage an imported ticket lands on. Carried across board
    # tabs (each is a turbo-frame reload) so the START AT choice sticks.
    @start_stage = params[:start_stage].to_s.presence_in(%w[briefing details]) || "briefing"

    if backlog_selected?
      @backlog_tasks = filtered_backlog_tasks
    else
      load_kanban_board
    end
  end

  private

  def backlog_selected?
    @selected_board_id == BACKLOG_BOARD_ID
  end

  def base_tasks
    return Task.none unless current_workshop_project
    current_workshop_project.tasks.jira_synced.where(in_pipeline: false)
  end

  def load_kanban_board
    @board = @boards.find_by(id: @selected_board_id)
    return unless @board

    @sprint = @board.jira_sprints.active_or_future.order(:name).first
    @columns = @board.jira_board_columns.includes(:jira_board_column_statuses)

    tasks = base_tasks
    @tasks_by_column = {}
    @columns.each do |column|
      @tasks_by_column[column.id] = tasks.where(jira_status_name: column.status_names).order(:name)
    end
  end

  def filtered_backlog_tasks
    scope = base_tasks.where(sprint_id: nil)
    scope = scope.where(issue_type: params[:type]) if params[:type].present? && params[:type] != "all"

    order_sql = case params[:sort]
                when "points"  then POINTS_ORDER_SQL
                when "newest"  then "#{DATE_COALESCE_SQL} DESC"
                when "oldest"  then "#{DATE_COALESCE_SQL} ASC"
                when "title"   then "tasks.name ASC"
                else PRIORITY_ORDER_SQL
                end

    scope.reorder(Arel.sql(order_sql))
  end
end
