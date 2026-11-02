# One context a setup run signs in to the test environment as (see
# AddDesignSetupInputs). The password is encrypted, never rendered back and
# never logged; it reaches the sign-in script only on its stdin
# (Designs::SignIn), and never the browser or Claude.
class DesignSetupRole < ApplicationRecord
  belongs_to :project

  encrypts :password

  validates :name, :login_url, :username, presence: true
  validates :password, presence: true, on: :create
  validates :login_url, format: { with: %r{\Ahttps?://[^\s]+\z}i, message: "must be an http(s) address" }, allow_blank: true
end
