class ProfilesController < ApplicationController
  include WorkspaceScoped

  def show
  end

  def update
    if params[:user][:password].present?
      unless current_user.authenticate(params[:user][:current_password])
        current_user.errors.add(:current_password, "is incorrect")
        render :show, status: :unprocessable_entity
        return
      end
    end

    user_params = params.require(:user).permit(:name, :email_address, :timezone, :default_hourly_rate_dollars)

    # Convert dollars to cents
    if params[:user][:default_hourly_rate_dollars].present?
      user_params[:default_hourly_rate_cents] = (params[:user][:default_hourly_rate_dollars].to_f * 100).round
    end
    user_params.delete(:default_hourly_rate_dollars)

    # Handle password change
    if params[:user][:password].present?
      user_params[:password] = params[:user][:password]
      user_params[:password_confirmation] = params[:user][:password_confirmation]
    end

    if current_user.update(user_params)
      redirect_to profile_path, notice: "Profile updated."
    else
      render :show, status: :unprocessable_entity
    end
  end
end
