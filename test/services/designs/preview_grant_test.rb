require "test_helper"

class Designs::PreviewGrantTest < ActiveSupport::TestCase
  setup { @project = projects(:jira_project) }

  test "a grant names its project and its slot, a work-in-progress one included" do
    assert_equal [ @project, "wip/REC-1" ], Designs::PreviewGrant.read(Designs::PreviewGrant.issue(@project, "wip/REC-1"))
    assert_equal [ @project, "master" ], Designs::PreviewGrant.read(Designs::PreviewGrant.issue(@project, "master"))
  end

  test "a grant is short enough to read in a link, and fits the route's pattern" do
    grant = Designs::PreviewGrant.issue(@project, "wip/REC-1")
    assert_operator grant.length, :<, 80
    assert_match(/\A#{Designs::PreviewGrant::FORMAT.source}\z/, grant)
  end

  test "a grant that was changed or made up names nothing" do
    grant = Designs::PreviewGrant.issue(@project, "REC-1")
    other = projects(:plain_project)
    [
      grant.sub("REC-1", "REC-2"),
      grant.sub(/\A\d+/, other.id.to_s),
      grant.sub(/.\z/) { |last| last == "0" ? "1" : "0" },
      grant[0..-2],
      "#{@project.id}.master.zzzzzz.#{"0" * 32}",
      "", "nonsense"
    ].each { |forged| assert_nil Designs::PreviewGrant.read(forged), forged }
  end

  test "a grant runs out after its lifetime" do
    grant = Designs::PreviewGrant.issue(@project, "master")
    assert_not_nil Designs::PreviewGrant.read(grant, now: Time.current + Designs::PreviewGrant::LIFETIME - 1.minute)
    assert_nil Designs::PreviewGrant.read(grant, now: Time.current + Designs::PreviewGrant::LIFETIME + 1.minute)
  end

  test "a grant for a project that is gone names nothing" do
    grant = Designs::PreviewGrant.issue(Project.new(id: Project.maximum(:id) + 1), "master")
    assert_nil Designs::PreviewGrant.read(grant)
  end
end
