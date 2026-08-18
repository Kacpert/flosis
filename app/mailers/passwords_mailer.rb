class PasswordsMailer < ApplicationMailer
  # `host` keeps the reset link on whichever domain the request came from — a
  # link that jumps you to a different hostname than the one you just typed your
  # email into reads as a phishing attempt. Falls back to the configured
  # default_url_options host (app.flosis.com) when there's no request context.
  def reset(user, host: nil)
    @user = user
    @reset_url = edit_password_url(user.password_reset_token, **(host ? { host: host } : {}))
    mail subject: "Reset your password", to: user.email_address
  end
end
