require "test_helper"

class HolidayYearlyGrantJobTest < ActiveSupport::TestCase
  test "creates yearly grant for active members without existing grant" do
    # user :one already has a kacper_yearly_grant fixture (yearly_grant for current
    # year), so the job creates for :two (two_employee) and workspace_client_user
    # (workspace_client_membership, whose time_hr_access is on) — the two
    # memberships with time_hr_access and no grant yet.
    assert_difference "HolidayBalanceEntry.count", 2 do
      HolidayYearlyGrantJob.perform_now
    end

    entry = HolidayBalanceEntry.where(user: users(:two), entry_type: :yearly_grant).order(:created_at).last
    assert_equal 20, entry.days
    assert_match "Annual holiday grant for #{Date.current.year}", entry.note
  end

  test "an organization without Time & HR is granted no holidays" do
    workspaces(:one).update!(hr_access: false)

    assert_no_difference "HolidayBalanceEntry.count" do
      HolidayYearlyGrantJob.perform_now
    end
  end

  test "skips members without Time & HR access" do
    # Add a membership with Time & HR access switched off — nothing to do with
    # role, since the job grants purely on the time_hr_access flag.
    workspaces(:one).workspace_memberships.create!(user: User.create!(
      name: "Client User",
      email_address: "client@example.com",
      password: "password123"
    ), time_hr_access: false)

    count_before = HolidayBalanceEntry.yearly_grant.count
    HolidayYearlyGrantJob.perform_now
    # Grants go to :two and workspace_client_user (both have time_hr_access);
    # the new time_hr_access: false membership gets nothing.
    assert_equal count_before + 2, HolidayBalanceEntry.yearly_grant.count
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
