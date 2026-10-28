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

  test "the workspace still answers the same way while it holds the column" do
    workspaces(:one).update_columns(estimation_field_names: nil)

    assert_equal [ EstimationSettings::DEFAULT_ESTIMATION_FIELD_NAME ],
                 workspaces(:one).reload.estimation_field_names
  end
end
