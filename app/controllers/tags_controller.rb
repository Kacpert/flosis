class TagsController < ApplicationController
  include WorkspaceScoped

  before_action :set_tag, only: %i[edit update destroy]

  def index
    @tags = current_workspace.tags.order(:name)
  end

  def new
    @tag = current_workspace.tags.build
  end

  def create
    @tag = current_workspace.tags.build(tag_params)

    if @tag.save
      redirect_to tags_path, notice: "Tag created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @tag.update(tag_params)
      redirect_to tags_path, notice: "Tag updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @tag.destroy
    redirect_to tags_path, notice: "Tag deleted.", status: :see_other
  end

  private

  def set_tag
    @tag = current_workspace.tags.find(params[:id])
  end

  def tag_params
    params.require(:tag).permit(:name, :color)
  end
end
