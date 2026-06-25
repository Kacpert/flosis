require "test_helper"

class ProductAccessTest < ActiveSupport::TestCase
  setup do
    @ws = workspaces(:one)
  end

  test "owner can access both products" do
    @ws.update!(workshop_enabled: true)
    u = users(:one)
    assert u.can_access_time_hr?(@ws)
    assert u.can_access_workshop?(@ws)
    assert_equal [:time_hr, :workshop], u.accessible_products(@ws)
    assert_equal :time_hr, u.default_product(@ws)
  end

  test "employee defaults to time_hr only" do
    u = users(:two)
    assert u.can_access_time_hr?(@ws)
    assert_not u.can_access_workshop?(@ws)
    assert_equal [:time_hr], u.accessible_products(@ws)
    assert_equal :time_hr, u.default_product(@ws)
  end

  test "employee granted workshop access gets both" do
    u = users(:two)
    u.membership_for(@ws).update!(workshop_access: true)
    assert u.can_access_workshop?(@ws)
    assert_equal [:time_hr, :workshop], u.accessible_products(@ws)
  end

  test "workshop access is independent of the workspace workshop_enabled feature flag" do
    @ws.update!(workshop_enabled: false)
    u = users(:one)
    assert u.can_access_workshop?(@ws), "product access is per-user, not gated by the tab feature flag"
  end

  test "client is workshop-only (Jira Tasks), never time_hr" do
    u = users(:client_user)
    assert_not u.can_access_time_hr?(@ws)
    assert u.can_access_workshop?(@ws)
    assert_equal [:workshop], u.accessible_products(@ws)
    assert_equal :workshop, u.default_product(@ws)
  end

  test "can_access_product? validates the symbol" do
    u = users(:two)
    assert u.can_access_product?(@ws, :time_hr)
    assert u.can_access_product?(@ws, "time_hr")
    assert_not u.can_access_product?(@ws, :workshop)
  end
end
