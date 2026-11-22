# Profile Settings inside Flosis (designs/admin/profile.html): the person's own
# settings, the AI costs switch among them (SCRUM-70). It belongs to the
# person, not to a project, so no project is needed to open it.
class Workshop::ProfilesController < Workshop::BaseController
  include ProfileSettings

  skip_before_action :require_current_project!, :require_project_member!

  private

  def profile_settings_path
    workshop_profile_path
  end
end
