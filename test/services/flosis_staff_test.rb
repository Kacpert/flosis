require "test_helper"

class FlosisStaffTest < ActiveSupport::TestCase
  test "nobody is staff by default, a workspace admin included" do
    assert_not users(:one).flosis_staff?
  end

  test "grant and revoke by email" do
    FlosisStaff.grant!(users(:one).email_address)
    assert users(:one).reload.flosis_staff?
    FlosisStaff.revoke!(users(:one).email_address)
    assert_not users(:one).reload.flosis_staff?
  end

  test "an unknown email is an error, not a silent no-op" do
    assert_raises(ActiveRecord::RecordNotFound) { FlosisStaff.grant!("nobody@example.com") }
  end
end
