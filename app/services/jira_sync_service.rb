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
    sync_delivered_issues
  end

  # Populates the `delivered_issues` reporting mirror from a lightweight
  # ~400-day "done issues" pass. HR-BOUNDARY: these rows are NEVER written to
  # `tasks` — see DeliveredIssue for why (HR's Projects index renders
  # project.tasks.size, which must stay unaffected by historical done work).
  def sync_delivered_issues
    done_issues = @client.fetch_recent_done_issues(@project.external_reference, since: "-400d", story_points_field_id: story_points_field_id)
    return if done_issues.nil?

    done_issues.each do |issue|
      delivered = @project.delivered_issues.find_or_initialize_by(jira_key: issue[:key])
      delivered.update!(
        title: issue[:title],
        issue_type: issue[:issue_type],
        assignee_email: issue[:assignee_email],
        assignee_name: issue[:assignee_name],
        reporter_email: issue[:reporter_email],
        reporter_name: issue[:reporter_name],
        story_points: issue[:story_points],
        jira_created_at: issue[:jira_created_at],
        resolved_at: issue[:resolved_at]
      )
    end
  end

  # Clears all sprint assignments, then reassigns from active/future sprints.
  # AUTO-ESTIMATE (sprint trigger): when workspace.estimation_trigger ==
  # "sprint", enqueues AutoEstimateJob for any task that NEWLY gains a
  # sprint_id (was nil, now set) on a sprint that is not a "design" sprint —
  # design-sprint tasks (Project#design_sprint_tasks: name contains "design")
  # are still being shaped in the Idea pipeline and aren't ready to estimate.
  # Idempotent: a task that already had this sprint_id (unchanged) is not
  # re-enqueued.
  def sync_sprint_assignments
    trigger_on_sprint = @project.workspace.estimation_trigger == "sprint"
    previous_sprint_ids = trigger_on_sprint ? @project.tasks.jira_synced.pluck(:external_reference, :sprint_id).to_h : {}

    @project.tasks.jira_synced.where.not(sprint_id: nil).update_all(sprint_id: nil, sprint_name: nil)

    @project.jira_boards.each do |board|
      board.jira_sprints.where(state: %w[active future]).find_each do |sprint|
        issue_keys = @client.fetch_sprint_issue_keys(sprint.jira_sprint_id)
        next if issue_keys.empty?

        @project.tasks.jira_synced
          .where(external_reference: issue_keys)
          .update_all(sprint_id: sprint.jira_sprint_id, sprint_name: sprint.name)

        next unless trigger_on_sprint
        next if design_sprint_name?(sprint.name)

        newly_assigned_keys = issue_keys.select { |key| previous_sprint_ids[key].nil? }
        next if newly_assigned_keys.empty?

        @project.tasks.jira_synced.where(external_reference: newly_assigned_keys).find_each do |task|
          AutoEstimateJob.perform_later(task.id)
        end
      end
    end
  end

  def design_sprint_name?(name)
    name.to_s.match?(/design/i)
  end

  # Cap on BugAttributionJob enqueues per sync run — bounds CLI cost when a
  # large batch of Bugs syncs at once (e.g. first sync of a new project).
  BUG_ATTRIBUTION_CAP = 3

  def sync_issues
    trigger_on_status = @project.workspace.estimation_trigger == "status"
    status_trigger = @project.workspace.estimation_status_trigger

    issues = @client.fetch_issues(@project.external_reference, story_points_field_id: story_points_field_id)
    return if issues.nil?

    bug_attributions_enqueued = 0

    issues.each do |issue|
      previous_status = trigger_on_status ? @project.tasks.jira_synced.find_by(external_reference: issue[:key])&.jira_status_name : nil

      sync_issue(issue)

      if trigger_on_status
        if previous_status != status_trigger && issue[:status_name] == status_trigger
          task = @project.tasks.jira_synced.find_by(external_reference: issue[:key])
          AutoEstimateJob.perform_later(task.id) if task
        end
      end

      next unless issue[:issue_type] == "Bug"
      next if bug_attributions_enqueued >= BUG_ATTRIBUTION_CAP
      next if BugAttribution.exists?(project_id: @project.id, jira_key: issue[:key])

      BugAttributionJob.perform_later(@project.id, issue[:key])
      bug_attributions_enqueued += 1
    end
  end

  private

  # Resolves + caches the Jira custom field id used for story points on the
  # project's workspace (mirrors JiraWriter#ai_actions_field_id's caching).
  def story_points_field_id
    workspace = @project.workspace
    return workspace.jira_story_points_field_id if workspace.jira_story_points_field_id.present?

    id = @client.resolve_story_points_field
    workspace.update_column(:jira_story_points_field_id, id) if id.present?
    id
  end

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
      jira_updated_at: issue[:updated],
      labels: issue[:labels]&.to_json,
      reporter_email: issue[:reporter_email],
      reporter_name: issue[:reporter_name],
      sprint_id: issue[:sprint_id],
      sprint_name: issue[:sprint_name],
      time_estimate_seconds: issue[:time_estimate_seconds],
      story_points: issue[:story_points],
      jira_created_at: issue[:jira_created_at]
    )

    ActiveRecord::Base.transaction(requires_new: true) do
      task.save!
    end

    sync_attachments(task, issue[:attachments] || [])
    sync_comments(task, @client.fetch_all_comments(issue[:key]))
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    task.name = "#{issue[:key]} #{issue[:summary]} [#{issue[:key]}]"
    ActiveRecord::Base.transaction(requires_new: true) { task.save! }
    sync_attachments(task, issue[:attachments] || [])
    sync_comments(task, @client.fetch_all_comments(issue[:key]))
  rescue StandardError => e
    Rails.logger.warn("[JiraSyncService] Failed to sync #{issue[:key]}: #{e.message}")
  end

  def sync_comments(task, comments)
    incoming_ids = comments.map { |c| c[:jira_id].to_s }
    # Remove comments that disappeared on Jira
    task.jira_comments.where.not(jira_comment_id: incoming_ids).destroy_all if incoming_ids.any?
    task.jira_comments.destroy_all if comments.empty?

    comments.each do |c|
      comment = task.jira_comments.find_or_initialize_by(jira_comment_id: c[:jira_id].to_s)
      comment.update!(
        author_name: c[:author_name],
        author_email: c[:author_email],
        body: c[:body],
        body_adf: c[:body_adf],
        jira_created_at: c[:created],
        jira_updated_at: c[:updated]
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[JiraSyncService] Comment sync failed for #{task.external_reference}: #{e.message}")
  end

  def sync_attachments(task, attachments)
    return if attachments.empty?

    existing_jira_ids = task.attachments.map { |a| a.blob.metadata["jira_id"].to_s }.to_set
    incoming_jira_ids = attachments.map { |a| a[:jira_id].to_s }.to_set

    # Remove attachments that are no longer on the Jira issue
    task.attachments.each do |att|
      jira_id = att.blob.metadata["jira_id"].to_s
      att.purge if jira_id.present? && !incoming_jira_ids.include?(jira_id)
    end

    # Fetch and store any new ones
    attachments.each do |meta|
      next if existing_jira_ids.include?(meta[:jira_id].to_s)

      data = @client.download_attachment(meta[:content_url])
      next unless data

      task.attachments.attach(
        io: StringIO.new(data),
        filename: meta[:filename],
        content_type: meta[:mime_type],
        metadata: { jira_id: meta[:jira_id], created: meta[:created] }
      )
    end

    # Mirror to disk so Claude can read paths directly.
    sync_attachments_to_disk(task)
  rescue StandardError => e
    Rails.logger.warn("[JiraSyncService] Attachment sync failed for #{task.external_reference}: #{e.message}")
  end

  def sync_attachments_to_disk(task)
    dir = task.attachments_disk_dir
    return unless dir

    FileUtils.mkdir_p(dir)
    # Clear and rewrite the directory so it reflects current attachments
    Dir.glob(File.join(dir, "*")).each { |f| File.delete(f) if File.file?(f) }

    task.attachments.each do |att|
      path = File.join(dir, sanitize_filename(att.filename.to_s))
      File.open(path, "wb") { |f| f.write(att.download) }
    end
  end

  def sanitize_filename(name)
    name.gsub(/[^\w.\- ]/, "_").gsub(/\s+/, "_")
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
