# What a feature of a setup run did to the components, as its row on the
# progress screen says: the component folders it added, and the components
# its screens include that were there before it.
module Designs::ComponentCount
  INCLUDE = %r{<x-include\b[^>]*\bsrc\s*=\s*["']components/([^/"']+)/}i

  module_function

  # { new:, reused: } for the commits after from up to to (from nil: all of
  # them up to to).
  def between(repo, from, to)
    return { new: 0, reused: 0 } unless to

    before = from ? names(repo.ls_files(from, "components/")) : Set.new
    added = names(repo.ls_files(to, "components/")) - before
    used = repo.diff_names(from, to, "designs/").flat_map { |path| repo.read_file(to, path).to_s.scan(INCLUDE).flatten }.to_set
    { new: added.size, reused: (used & before).size }
  end

  def names(paths)
    paths.filter_map { |path| path.split("/")[1] if path.count("/") >= 2 }.to_set
  end
end
