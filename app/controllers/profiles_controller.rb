# Time & HR's Profile Settings. Flosis has its own, Workshop::ProfilesController;
# both share ProfileSettings.
class ProfilesController < ApplicationController
  include WorkspaceScoped
  include ProfileSettings

  private

  def profile_settings_path
    profile_path
  end
end
