require "test_helper"

# Invitations are sent as Flosis and link to app.flosis.com, so they speak of
# Flosis: "Clar" was the platform's name before the rebrand, and a mail whose
# words, sender and links name three different things reads as phishing (and
# lands in spam).
class InvitationMailerTest < ActionMailer::TestCase
  setup do
    @user = users(:one)
    @workspace = workspaces(:one)
  end

  test "an invitation speaks of Flosis" do
    mail = InvitationMailer.welcome(@user, @workspace)
    assert_equal "You've been invited to #{@workspace.name} on Flosis", mail.subject
    [ mail.html_part.body.to_s, mail.text_part.body.to_s ].each do |body|
      assert_includes body, "on Flosis"
      assert_not_includes body, "Clar"
    end
  end

  test "being added to a workspace speaks of Flosis" do
    mail = InvitationMailer.added_to_workspace(@user, @workspace)
    assert_equal "You've been added to #{@workspace.name} on Flosis", mail.subject
    [ mail.html_part.body.to_s, mail.text_part.body.to_s ].each do |body|
      assert_includes body, "on Flosis"
      assert_not_includes body, "Clar"
    end
  end

  test "a workspace named Flosis is not Flosis on Flosis" do
    @workspace.update!(name: "Flosis")
    { InvitationMailer.welcome(@user, @workspace) => "You've been invited to Flosis",
      InvitationMailer.added_to_workspace(@user, @workspace) => "You've been added to Flosis" }.each do |mail, subject|
      assert_equal subject, mail.subject
      [ mail.html_part.body.to_s, mail.text_part.body.to_s ].each { |body| assert_not_includes body, "Flosis on Flosis" }
    end
  end

  test "every mail is signed by Flosis" do
    body = InvitationMailer.welcome(@user, @workspace).html_part.body.to_s
    assert_includes body, "Sent by Flosis"
  end
end
