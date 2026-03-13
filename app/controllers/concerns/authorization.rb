module Authorization
  extend ActiveSupport::Concern

  included do
    helper_method :current_membership, :can_see_money?
  end

  private

  def current_membership
    @current_membership ||= current_user&.membership_for(current_workspace)
  end

  def current_role
    current_membership&.role
  end

  def require_admin!
    unless current_user&.admin_or_owner?(current_workspace)
      redirect_to root_path, alert: "You don't have permission to access this page."
    end
  end

  def require_employee!
    unless current_user&.at_least_employee?(current_workspace)
      redirect_to reports_summary_path, alert: "You don't have permission to access this page."
    end
  end

  def can_see_money?
    current_user&.can_see_money?(current_workspace)
  end
end
