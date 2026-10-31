require "test_helper"

class DesignApprovalTest < ActiveSupport::TestCase
  setup { @task = tasks(:local_task) }

  def approve(number, task: @task, **attrs)
    DesignApproval.create!({ task: task, user: users(:one), number: number, design_sha: "a" * 40,
                             master_sha: "b" * 40, tag: "approved/ELV-9/#{number}" }.merge(attrs))
  end

  test "an approval records who approved which task, and when" do
    approval = approve(1)
    assert_equal @task, approval.task
    assert_equal users(:one), approval.user
    assert approval.created_at
    assert_equal [ approval ], @task.design_approvals.to_a
  end

  # The number is the approval tag's, and a tag exists once: two people
  # approving at once must not both become version 2.
  test "a task has each approval number once" do
    approve(1)
    assert_raises(ActiveRecord::RecordNotUnique) { approve(1) }
    assert approve(2).persisted?
    assert approve(1, task: tasks(:jira_task)).persisted?, "numbers are counted per task"
  end

  test "an approval needs its number, both shas and its tag" do
    %i[number design_sha master_sha tag].each do |attribute|
      assert_raises(ActiveRecord::NotNullViolation, attribute.to_s) { approve(1, attribute => nil) }
    end
  end

  test "destroying a task destroys its approvals" do
    approve(1)
    assert_difference "DesignApproval.count", -1 do
      @task.destroy!
    end
  end
end
