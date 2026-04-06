require "test_helper"

class HolidayYearlyGrantJobTest < ActiveSupport::TestCase
  test "creates yearly grant for active members without existing grant" do
    # user :one already has a kacper_yearly_grant fixture (yearly_grant for current year)
    # so the job should only create for user :two
    assert_difference "HolidayBalanceEntry.count", 1 do
      HolidayYearlyGrantJob.perform_now
    end

    entry = HolidayBalanceEntry.where(user: users(:two), entry_type: :yearly_grant).order(:created_at).last
    assert_equal 20, entry.days
    assert_match "Annual holiday grant for #{Date.current.year}", entry.note
  end

  test "skips client role members" do
    # Add a client membership
    workspaces(:one).workspace_memberships.create!(user: User.create!(
      name: "Client User",
      email_address: "client@example.com",
      password: "password123"
    ), role: :client)

    count_before = HolidayBalanceEntry.yearly_grant.count
    HolidayYearlyGrantJob.perform_now
    # Should only create for user :two (user :one already has yearly_grant fixture), not the client
    assert_equal count_before + 1, HolidayBalanceEntry.yearly_grant.count
  end

  test "idempotent — does not duplicate grants" do
    HolidayYearlyGrantJob.perform_now
    initial_count = HolidayBalanceEntry.yearly_grant.where(
      "created_at >= ?", Date.current.beginning_of_year
    ).count

    HolidayYearlyGrantJob.perform_now
    final_count = HolidayBalanceEntry.yearly_grant.where(
      "created_at >= ?", Date.current.beginning_of_year
    ).count

    assert_equal initial_count, final_count
  end
end
