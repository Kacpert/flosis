class InvitationMailer < ApplicationMailer
  def welcome(user, workspace)
    invite(user, workspace)
    mail to: user.email_address, subject: "You've been invited to #{place}"
  end

  def added_to_workspace(user, workspace)
    invite(user, workspace)
    mail to: user.email_address, subject: "You've been added to #{place}"
  end

  private

  # A workspace named Flosis is just "Flosis", never "Flosis on Flosis".
  def invite(user, workspace)
    @user = user
    @workspace = workspace
    @on_flosis = !workspace.name.to_s.strip.casecmp?("Flosis")
  end

  def place = @on_flosis ? "#{@workspace.name} on Flosis" : @workspace.name
end
