require "openssl"

# A short-lived grant to see one slot of one project's published designs: the
# <grant> in /<organization>/<project>/<grant>/design/<page>, under which
# Designs::PreviewsController serves the page sandboxed. Whoever opens a
# lasting link signs in first and is sent on with one
# (Designs::PreviewEntriesController); the Designs screen shows its work in
# progress under one.
#
# It reads <project id>.<slot>.<expiry>.<signature>, with the slot's / written
# as ~ and the expiry in base 36. The signature is an HMAC of the rest under a
# key derived from the app's secret, so a grant cannot be made up or changed,
# and it runs out after LIFETIME: a link copied out of a screen stops working
# within hours.
class Designs::PreviewGrant
  LIFETIME = 12.hours

  # What a grant looks like, for the route. A task's key never has a dot.
  FORMAT = /\d+\.[A-Za-z0-9_~-]+\.[0-9a-z]+\.[0-9a-f]{32}/

  def self.issue(project, slot, now: Time.current)
    body = [ project.id, slot.tr("/", "~"), (now + LIFETIME).to_i.to_s(36) ].join(".")
    "#{body}.#{signature(body)}"
  end

  # [project, slot], or nil when the grant was made up, changed or has run out.
  def self.read(grant, now: Time.current)
    body, _, signed = grant.to_s.rpartition(".")
    return unless ActiveSupport::SecurityUtils.secure_compare(signed, signature(body))

    id, slot, expiry = body.split(".", 3)
    return unless expiry.to_s.to_i(36) > now.to_i

    project = Project.find_by(id: id)
    [ project, slot.tr("~", "/") ] if project
  end

  def self.signature(body)
    OpenSSL::HMAC.hexdigest("SHA256", key, body).first(32)
  end
  private_class_method :signature

  def self.key
    @key ||= Rails.application.key_generator.generate_key("designs preview grants", 32)
  end
  private_class_method :key
end
