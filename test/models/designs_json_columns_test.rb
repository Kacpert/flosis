require "test_helper"

# Production is MariaDB, which reports a JSON column as `longtext CHECK
# (json_valid(...))` and so types it :text unless the model says :json: a
# Hash or an array of hashes is then written as Ruby inspect and rejected by
# the check (see DesignRequest#links). Postgres, where the tests run, types the
# column :json by itself, so only the model's own declaration protects
# production. Every JSON column Workshop Designs v2 added must have one.
class DesignsJsonColumnsTest < ActiveSupport::TestCase
  COLUMNS = { ChatMessage => %w[data], DesignMerge => %w[screens what_changed], Project => %w[design_app_repos],
              DesignSetup => %w[notes step_seconds], DesignSetupFeature => %w[contexts screens notes] }.freeze

  test "the JSON columns Designs v2 added are declared :json in their models" do
    COLUMNS.each do |model, columns|
      columns.each do |column|
        # Rails 8.1 keeps a model's own `attribute` declarations here (private).
        declared = model.send(:pending_attribute_modifications).select { _1.respond_to?(:name) }.map { _1.name.to_s }
        assert_includes declared, column, "#{model}##{column} needs `attribute :#{column}, :json`"
      end
    end
  end

  test "what they hold reaches the column as JSON" do
    project = projects(:jira_project)
    project.update!(design_app_repos: [ { "role" => "Frontend", "repo" => "acme/app" } ])
    raw = Project.connection.select_value("SELECT design_app_repos FROM projects WHERE id = #{project.id}")
    assert_equal [ { "role" => "Frontend", "repo" => "acme/app" } ], JSON.parse(raw.to_s)

    merge = DesignMerge.create!(project: project, sha: "a3f9c21", title: "t", branch: "design/x", how: "manual",
                                screens: [ "admin/pipeline" ], what_changed: [ "Stage colours" ], merged_at: Time.current)
    raw = DesignMerge.connection.select_rows("SELECT screens, what_changed FROM design_merges WHERE id = #{merge.id}").first
    assert_equal [ [ "admin/pipeline" ], [ "Stage colours" ] ], raw.map { JSON.parse(_1.to_s) }
  end
end
