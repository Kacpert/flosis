class PasswordsMailer < ApplicationMailer
  # `host` keeps the reset link on whichever domain the request came from —
  # flosis.com and clar.rubyonsaas.com are the same app behind two names, and a
  # link that jumps you to the other one reads as a phishing attempt. Falls back
  # to the configured default_url_options host when there's no request context.
  def reset(user, host: nil)
    @user = user
    @reset_url = edit_password_url(user.password_reset_token, **(host ? { host: host } : {}))
    mail subject: "Reset your password", to: user.email_address
  end
end
