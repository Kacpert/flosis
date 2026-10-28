require "test_helper"

# The two shapes production actually returns: MySQL's raw JSON string, and the
# NULL that the AI tab writes whenever every box is unticked.
class EstimationSettingsTest < ActiveSupport::TestCase
  test "a raw JSON string normalizes to an array" do
    project = projects(:jira_project)
    project.update_columns(estimation_field_names: nil)
    project.estimation_field_names = nil
    project.write_attribute(:estimation_field_names, '["Story point estimate"]')

    assert_equal [ "Story point estimate" ], project.estimation_field_names
  end

  test "nothing chosen falls back to the one default field" do
    project = projects(:jira_project)
    project.update_columns(estimation_field_names: nil)

    assert_equal [ EstimationSettings::DEFAULT_ESTIMATION_FIELD_NAME ],
                 project.reload.estimation_field_names
  end

  # The workspace held these columns during the transition and answered the
  # same way. It no longer holds them, and the concern is off it entirely.
  test "the workspace no longer answers for estimation at all" do
    assert_not Workspace.include?(EstimationSettings)
    assert_not Workspace.new.respond_to?(:estimation_field_names)
  end
end
