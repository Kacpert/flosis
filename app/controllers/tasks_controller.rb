class TasksController < ApplicationController
  include WorkspaceScoped

  def create
    @project = current_workspace.projects.find(params[:project_id])
    @task = @project.tasks.build(task_params)

    if @task.save
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to @project, notice: "Task added." }
      end
    else
      redirect_to @project, alert: @task.errors.full_messages.join(", ")
    end
  end

  def destroy
    @task = Task.find(params[:id])
    project = @task.project
    return head(:forbidden) unless project.workspace_id == current_workspace.id

    @task.destroy
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to project, notice: "Task removed.", status: :see_other }
    end
  end

  def list
    @project = current_workspace.projects.find(params[:project_id])
    @tasks = @project.tasks.active.order(:name)
    render partial: "tasks/options", locals: { tasks: @tasks }
  end

  private

  def task_params
    params.require(:task).permit(:name)
  end
end
