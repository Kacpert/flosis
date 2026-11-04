# A personal access token (PAT): lets a script or another AI act as one person
# in one workspace, holding nothing but the abilities named in `scopes`. The
# raw token is returned once, by .issue!; only its SHA-256 digest is kept, so a
# lost token is revoked and reissued, never recovered.
class ApiToken < ApplicationRecord
  PREFIX = "gold_pat_".freeze

  # time_entries:create — book completed hours against one's own projects.
  # time_entries:delete — delete one's own entries from the last 36 days.
  # projects:read       — list the projects one may book hours against.
  SCOPES = %w[time_entries:create time_entries:delete projects:read].freeze

  belongs_to :user
  belongs_to :workspace

  validates :name, :token_digest, :token_hint, :scopes, presence: true
  validates :token_digest, uniqueness: true
  validate :scopes_are_known

  scope :live, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  # Returns [token, raw]. The raw string exists only in the return value.
  def self.issue!(user:, workspace:, name:, scopes: SCOPES, expires_at: nil)
    raw = PREFIX + SecureRandom.base58(40)
    token = create!(user: user, workspace: workspace, name: name, scopes: Array(scopes).join(" "),
                    expires_at: expires_at, token_digest: digest(raw), token_hint: raw.last(4))
    [ token, raw ]
  end

  def self.authenticate(raw)
    return if raw.blank? || !raw.start_with?(PREFIX)

    live.find_by(token_digest: digest(raw))
  end

  def self.digest(raw)
    OpenSSL::Digest::SHA256.hexdigest(raw)
  end

  def scope_list
    scopes.to_s.split
  end

  def allows?(scope)
    scope_list.include?(scope.to_s)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  # At most one write a minute, so a busy client does not turn every request
  # into an UPDATE.
  def touch_last_used!
    return if last_used_at && last_used_at > 1.minute.ago

    update_column(:last_used_at, Time.current)
  end

  private

  def scopes_are_known
    unknown = scope_list - SCOPES
    errors.add(:scopes, "unknown: #{unknown.join(', ')}") if unknown.any?
  end
end
