# One context a setup run signs in to the test environment as (see
# AddDesignSetupInputs). The password is encrypted, never rendered back and
# never logged; it reaches the sign-in script only on its stdin
# (Designs::SignIn), and never the browser or Claude.
class DesignSetupRole < ApplicationRecord
  belongs_to :project

  # Whether it signs in to the test environment (a code-only one does not).
  def signs_in? = !code_only?

  encrypts :password

  # A code-only context (Kacper, 2026-11-22) has no login: it is never
  # signed in, and its screens are built from the app's code.
  validates :name, presence: true
  validates :login_url, :username, presence: true, unless: :code_only?
  validates :password, presence: true, on: :create, unless: :code_only?
  validates :login_url, format: { with: %r{\Ahttps?://[^\s]+\z}i, message: "must be an http(s) address" }, allow_blank: true
end
