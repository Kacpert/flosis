require "test_helper"

class Workshop::DesignRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    workspaces(:one).update!(workshop_enabled: true)
    sign_in_as(users(:one)) # admin/owner
    post switch_product_path, params: { product: "workshop" }
    @idea = tasks(:jira_task)
    @idea.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
  end

  # Minimal fake JiraWriter recording calls, same shape used elsewhere in the
  # suite (see JiraWriterTest's fake_client) — stubs the instance method so the
  # controller's `JiraWriter.new(workspace: ...).sync_design_links(...)` call
  # never reaches the network.
  def stub_sync_design_links(result = { ok: true })
    calls = []
    orig = JiraWriter.instance_method(:sync_design_links)
    JiraWriter.define_method(:sync_design_links) { |task, links| calls << { task: task, links: links }; result }
    yield calls
  ensure
    JiraWriter.define_method(:sync_design_links, orig)
  end

  test "create requests designs from a picked designer with an optional note" do
    assert_difference -> { DesignRequest.count }, 1 do
      post workshop_idea_design_request_path(@idea), params: {
        design_request: { designer_id: users(:two).id, note: "Please cover empty states" }
      }
    end

    dr = @idea.reload.design_request
    assert_equal "requested", dr.status
    assert_equal users(:two), dr.designer
    assert_equal users(:one), dr.requester
    assert_equal "Please cover empty states", dr.note
    assert_redirected_to workshop_idea_path(@idea, stage: "details")
    assert_match "Design request sent to #{users(:two).name}", flash[:clar_toast]
  end

  test "create is scope-safe (404s for an idea outside the current workshop project)" do
    other = tasks(:secret_task)
    other.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)

    post workshop_idea_design_request_path(other), params: { design_request: { designer_id: users(:two).id } }

    assert_response :not_found
    assert_nil other.reload.design_request
  end

  test "update with kind=deliver adds link rows, marks delivered, and syncs to Jira" do
    dr = DesignRequest.create!(task: @idea, requester: users(:one), designer: users(:two))

    stub_sync_design_links do |calls|
      patch workshop_idea_design_request_path(@idea), params: {
        kind: "deliver",
        design_request: { links: [
          { name: "Results · Export flow", url: "https://figma.com/file/a" },
          { name: "", url: "https://figma.com/file/b" }
        ] }
      }

      assert_equal 1, calls.size
      assert_equal @idea, calls.first[:task]
    end

    dr.reload
    assert dr.delivered?
    assert_not_nil dr.delivered_at
    assert_equal "Results · Export flow", dr.links[0]["name"]
    assert_equal "https://figma.com/file/a", dr.links[0]["url"]
    assert_equal "Figma frame 2", dr.links[1]["name"], "a blank name auto-fills as 'Figma frame {n}'"
    assert_match "Designs delivered", flash[:clar_toast]
    assert_match "2 links added to Jira description", flash[:clar_toast]
  end

  test "update with kind=request_changes moves delivered back to requested and keeps links" do
    dr = DesignRequest.create!(task: @idea, requester: users(:one), designer: users(:two))
    dr.deliver!([{ "name" => "Frame 1", "url" => "https://figma.com/file/a" }])

    stub_sync_design_links do
      patch workshop_idea_design_request_path(@idea), params: {
        kind: "request_changes", design_request: { designer_id: users(:one).id, note: "Needs another pass" }
      }
    end

    dr.reload
    assert dr.requested?
    assert_equal 1, dr.links.size
    assert_equal users(:one), dr.designer
    assert_equal "Needs another pass", dr.note
    assert_match "Design request", flash[:clar_toast]
  end

  test "update removing all links via kind=deliver with an empty list still syncs (removes the Jira block)" do
    dr = DesignRequest.create!(task: @idea, requester: users(:one), designer: users(:two))
    dr.deliver!([{ "name" => "Frame 1", "url" => "https://figma.com/file/a" }])

    stub_sync_design_links do |calls|
      patch workshop_idea_design_request_path(@idea), params: {
        kind: "deliver", design_request: { links: [{ name: "Frame 1", url: "" }] }
      }
      assert_equal [], calls.first[:links]
    end

    assert_equal [], dr.reload.links
  end

  test "destroy cancels the design request" do
    dr = DesignRequest.create!(task: @idea, requester: users(:one), designer: users(:two))

    delete workshop_idea_design_request_path(@idea)

    assert dr.reload.cancelled?
    assert_match "Design request cancelled", flash[:clar_toast]
  end

  test "destroy is scope-safe (404s for an idea outside the current workshop project)" do
    other = tasks(:secret_task)
    other.update!(in_pipeline: true, workshop_stage: "details", pipeline_entered_at: 1.hour.ago)
    dr = DesignRequest.create!(task: other, requester: users(:one), designer: users(:two))

    delete workshop_idea_design_request_path(other)

    assert_response :not_found
    assert dr.reload.requested?
  end
end
