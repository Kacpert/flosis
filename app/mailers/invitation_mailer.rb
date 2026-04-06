class InvitationMailer < ApplicationMailer
  def welcome(user, workspace)
    @user = user
    @workspace = workspace
    mail to: user.email_address, subject: "You've been invited to #{workspace.name} on Clar"
  end

  def added_to_workspace(user, workspace)
    @user = user
    @workspace = workspace
    mail to: user.email_address, subject: "You've been added to #{workspace.name} on Clar"
  end
end
