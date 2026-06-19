module Reports
  class ProjectReportsController < ApplicationController
    include WorkspaceScoped
    before_action :require_admin!

    def show
      @projects = current_workspace.projects.active.order(:name)
      @project = @projects.find_by(id: params[:project_id]) || @projects.first
      @month = parse_month(params[:month])

      @report = ProjectMonthlyReport.new(project: @project, month: @month) if @project
    end

    private

    def parse_month(value)
      Date.strptime(value, "%Y-%m").beginning_of_month
    rescue ArgumentError, TypeError
      Date.current.beginning_of_month
    end
  end
end
