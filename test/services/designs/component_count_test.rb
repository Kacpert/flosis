require "test_helper"

# What a feature did to the components, as its row on the progress screen
# says it: the components it added, and those its screens include that were
# there before it.
class Designs::ComponentCountTest < ActiveSupport::TestCase
  include DesignRepoTestHelper

  test "the components a range added, and the ones its screens reused" do
    with_design_remote do |repo, remote|
      with_remote_url(remote) do
        seed_master(repo)
        dir = repo.worktree!("wip/setup", from: "master")
        commit_files(repo, dir, { "components/button/button.html" => "<button></button>", "components/card/card.html" => "<div></div>" })
        first = repo.head("wip/setup")
        commit_files(repo, dir, {
          "components/table/table.html" => "<table></table>",
          "designs/admin/reports.html" => %(<x-include src="components/button/button.html" title="Go"></x-include>) +
                                          %(<x-include src='components/table/table.html'></x-include><x-include src="components/button/button.html"></x-include>)
        })
        second = repo.head("wip/setup")

        assert_equal({ new: 1, reused: 1 }, Designs::ComponentCount.between(repo, first, second))
        assert_equal({ new: 3, reused: 0 }, Designs::ComponentCount.between(repo, nil, second))
        assert_equal({ new: 0, reused: 0 }, Designs::ComponentCount.between(repo, second, second))
        assert_equal({ new: 0, reused: 0 }, Designs::ComponentCount.between(repo, second, nil))
      end
    end
  end
end
