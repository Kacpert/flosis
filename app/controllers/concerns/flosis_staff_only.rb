# For what only Flosis staff may reach (users.flosis_staff): anyone else gets
# a 404, so the page's existence is not confirmed, workspace admins included.
# It runs after the Workshop shell's own checks (sign-in among them), which a
# prepended check would run before.
module FlosisStaffOnly
  extend ActiveSupport::Concern

  included do
    before_action :require_flosis_staff!
  end

  private

  def require_flosis_staff!
    raise ActionController::RoutingError, "Not Found" unless current_user&.flosis_staff?
  end
end
