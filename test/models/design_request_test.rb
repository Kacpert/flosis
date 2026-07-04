require "test_helper"

class DesignRequestTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:jira_task)
    @requester = users(:one)
    @designer = users(:two)
  end

  test "links defaults to an empty array on a new record (MySQL JSON columns cannot carry a DB default)" do
    dr = DesignRequest.new(task: @task, requester: @requester, designer: @designer)
    assert_equal [], dr.links
  end

  test "links defaults to [] even for a persisted record round-tripped from the DB" do
    dr = DesignRequest.create!(task: @task, requester: @requester, designer: @designer)
    assert_equal [], dr.reload.links
  end

  # On MySQL (production) a :json column can come back as a raw JSON *string*.
  # The reader must normalize to an Array so views (.each_with_index/.size/.map)
  # don't 500 with "undefined method 'each' for a String".
  test "links normalizes a raw JSON string (MySQL) into an Array of hashes" do
    dr = DesignRequest.new(task: @task, requester: @requester, designer: @designer)
    normalized = dr.send(:links_from, %q([{"name":"Frame 1","url":"https://figma.com/x"}]))
    assert_kind_of Array, normalized
    assert_equal "Frame 1", normalized.first["name"]
    assert_nothing_raised { normalized.each_with_index { |l, i| l }; normalized.size }
  end

  test "links normalizer tolerates malformed / blank / nil raw values" do
    dr = DesignRequest.new(task: @task, requester: @requester, designer: @designer)
    assert_equal [], dr.send(:links_from, nil)
    assert_equal [], dr.send(:links_from, "")
    assert_equal [], dr.send(:links_from, "not json")
    assert_equal [{ "url" => "x" }], dr.send(:links_from, [{ "url" => "x" }])
  end

  test "defaults to status requested on create" do
    dr = DesignRequest.create!(task: @task, requester: @requester, designer: @designer)
    assert_equal "requested", dr.status
    assert dr.requested?
  end

  test "deliver! transitions requested to delivered, sets delivered_at, and stores links" do
    dr = DesignRequest.create!(task: @task, requester: @requester, designer: @designer)
    links = [{ "name" => "Figma frame 1", "url" => "https://figma.com/file/abc" }]

    dr.deliver!(links)

    assert dr.delivered?
    assert_not_nil dr.delivered_at
    assert_equal links, dr.links
  end

  test "cancel! transitions to cancelled" do
    dr = DesignRequest.create!(task: @task, requester: @requester, designer: @designer)

    dr.cancel!

    assert dr.cancelled?
  end

  test "request_changes! transitions delivered back to requested, keeping links" do
    dr = DesignRequest.create!(task: @task, requester: @requester, designer: @designer)
    links = [{ "name" => "Figma frame 1", "url" => "https://figma.com/file/abc" }]
    dr.deliver!(links)

    dr.request_changes!(designer: @requester)

    assert dr.requested?
    assert_equal links, dr.links, "request-changes must preserve link history"
    assert_equal @requester, dr.reload.designer, "request-changes may swap the designer"
  end

  test "unique per task: a second design_request on the same task is invalid" do
    DesignRequest.create!(task: @task, requester: @requester, designer: @designer)
    dup = DesignRequest.new(task: @task, requester: @requester, designer: @designer)

    assert_not dup.valid?
  end

  test "unique per task is enforced at the DB level too" do
    DesignRequest.create!(task: @task, requester: @requester, designer: @designer)

    assert_raises(ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique) do
      DesignRequest.new(task: @task, requester: @requester, designer: @designer).save!(validate: false)
    end
  end

  test "task has_one design_request" do
    dr = DesignRequest.create!(task: @task, requester: @requester, designer: @designer)
    assert_equal dr, @task.reload.design_request
  end
end
