class ProjectMembershipsController < ApplicationController
  include WorkspaceScoped

  before_action { require_product!(:time_hr) }

  before_action :require_admin!
  before_action :set_project

  def create
    user = User.find(params[:user_id])
    @membership = @project.project_memberships.build(
      user: user,
      hourly_rate_cents: (params[:hourly_rate_dollars].to_f * 100).round
    )

    if @membership.save
      redirect_to project_path(@project, tab: "members"), notice: "#{user.name} added to project."
    else
      redirect_to project_path(@project, tab: "members"), alert: @membership.errors.full_messages.to_sentence
    end
  end

  def update
    @membership = @project.project_memberships.find(params[:id])
    new_rate = (params[:hourly_rate_dollars].to_f * 100).round

    if @membership.update(hourly_rate_cents: new_rate)
      redirect_to project_path(@project, tab: "members"), notice: "Rate updated."
    else
      redirect_to project_path(@project, tab: "members"), alert: @membership.errors.full_messages.to_sentence
    end
  end

  def destroy
    @membership = @project.project_memberships.find(params[:id])
    name = @membership.user.name
    @membership.destroy
    redirect_to project_path(@project, tab: "members"), notice: "#{name} removed from project.", status: :see_other
  end

  private

  def set_project
    @project = current_workspace.projects.find(params[:project_id])
  end
end
