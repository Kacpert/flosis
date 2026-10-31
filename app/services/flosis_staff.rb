# Who is Flosis staff (users.flosis_staff), set by email from the command line:
# bin/rails "flosis:staff:grant[someone@example.com]". An email no user has is
# an error, so a typo never passes for a grant.
module FlosisStaff
  module_function

  def grant!(email)
    set!(email, true)
  end

  def revoke!(email)
    set!(email, false)
  end

  def set!(email, staff)
    User.find_by!(email_address: email.to_s.strip.downcase).tap { |user| user.update!(flosis_staff: staff) }
  end
  private_class_method :set!
end
