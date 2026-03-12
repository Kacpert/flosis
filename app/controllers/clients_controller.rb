class ClientsController < ApplicationController
  include WorkspaceScoped

  before_action :set_client, only: %i[show edit update destroy]

  def index
    @clients = current_workspace.clients.includes(:projects).order(:name)
    @clients = @clients.active unless params[:show_archived] == "1"
  end

  def show
    @projects = @client.projects.active.includes(:tasks)
  end

  def new
    @client = current_workspace.clients.build
  end

  def create
    @client = current_workspace.clients.build(client_params)

    if @client.save
      redirect_to clients_path, notice: "Client created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @client.update(client_params)
      redirect_to clients_path, notice: "Client updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @client.destroy
    redirect_to clients_path, notice: "Client deleted.", status: :see_other
  end

  private

  def set_client
    @client = current_workspace.clients.find(params[:id])
  end

  def client_params
    params.require(:client).permit(:name, :notes, :archived)
  end
end
