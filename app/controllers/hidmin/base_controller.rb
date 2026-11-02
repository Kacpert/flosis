# /hidmin, Flosis's own back office. It stands outside every workspace (no
# WorkspaceScoped), so a member of staff sees all organizations whichever one
# they happen to be in. Signed-out visitors are sent to sign in like anywhere
# else; signed-in people who aren't staff get a 404 (FlosisStaffOnly).
class Hidmin::BaseController < ApplicationController
  include FlosisStaffOnly

  layout "hidmin"

  private

  # When each person last signed in: one query for a whole page of people.
  def last_sign_ins(user_ids)
    Session.where(user_id: user_ids).group(:user_id).maximum(:created_at)
  end
  helper_method :last_sign_ins
end
