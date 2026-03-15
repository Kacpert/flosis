class JiraSyncService
  def initialize(project, client: nil)
    @project = project
    @client = client || JiraClient.new
  end

  def sync
    return unless @project.jira_connected?

    issues = @client.fetch_issues(@project.external_reference)
    return if issues.nil?

    issues.each do |issue|
      sync_issue(issue)
    end
  end

  private

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
      jira_status_name: issue[:status_name],
      status: map_status(issue[:status_category])
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
