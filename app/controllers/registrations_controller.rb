class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)

    ActiveRecord::Base.transaction do
      @user.save!
      workspace = Workspace.create!(name: "#{@user.name}'s Workspace")
      workspace.workspace_memberships.create!(user: @user, role: :owner)
    end

    start_new_session_for @user
    redirect_to root_path, notice: "Welcome to Gold!"
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  private

  def user_params
    params.require(:user).permit(:name, :email_address, :password, :password_confirmation)
  end
end
