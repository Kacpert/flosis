require "test_helper"

class ClientRoleTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:one)
    @client = users(:client_user)
    @employee = users(:two)
    @owner = users(:one)
  end

  test "client_role? is true only for client membership" do
    assert @client.client_role?(@workspace)
    assert_not @employee.client_role?(@workspace)
    assert_not @owner.client_role?(@workspace)
  end

  test "client_or_employee? is true for client, employee, owner" do
    assert @client.client_or_employee?(@workspace)
    assert @employee.client_or_employee?(@workspace)
    assert @owner.client_or_employee?(@workspace)
  end

  test "at_least_employee? excludes client" do
    assert_not @client.at_least_employee?(@workspace)
    assert @employee.at_least_employee?(@workspace)
  end

  test "client cannot see money" do
    assert_not @client.can_see_money?(@workspace)
  end
end
