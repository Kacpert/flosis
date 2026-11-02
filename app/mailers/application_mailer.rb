class ApplicationMailer < ActionMailer::Base
  # One sender name serves both products; "Clar" was the pre-rebrand name.
  default from: "Flosis <support@rubyonsaas.com>"
  layout "mailer"
end
