# Everyone with an account, across organizations. Staff can correct a name or
# an address and say who else is Flosis staff, but never take that away from
# themselves: the way back would be the command line.
class Hidmin::UsersController < Hidmin::BaseController
  before_action :set_user, only: %i[show update]

  def index
    @query = params[:q].to_s.strip
    users = User.order(:name)
    # LOWER on both sides rather than ILIKE: production is MariaDB, tests are PostgreSQL.
    if @query.present?
      pattern = "%#{User.sanitize_sql_like(@query.downcase)}%"
      users = users.where("LOWER(users.name) LIKE :q OR LOWER(users.email_address) LIKE :q", q: pattern)
    end
    @pagy, @users = pagy(users.includes(:workspaces), limit: 50)
  end

  def show
  end

  def update
    attrs = params.require(:user).permit(:name, :email_address, :flosis_staff)

    if @user == current_user && attrs.key?(:flosis_staff) && attrs[:flosis_staff] != "1"
      redirect_to hidmin_user_path(@user), alert: "You can't take staff access away from yourself."
    elsif @user.update(attrs)
      redirect_to hidmin_user_path(@user), notice: "Saved."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def set_user
    @user = User.find(params[:id])
  end
end
