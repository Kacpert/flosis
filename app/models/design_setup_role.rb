# One login a setup run crawls the app as (see AddDesignSetupInputs). The
# password is encrypted, never rendered back and never logged; it reaches the
# crawler only on its stdin.
class DesignSetupRole < ApplicationRecord
  belongs_to :project

  encrypts :password

  validates :name, :login_url, :username, presence: true
  validates :password, presence: true, on: :create
  validates :login_url, format: { with: %r{\Ahttps?://[^\s]+\z}i, message: "must be an http(s) address" }, allow_blank: true
end
