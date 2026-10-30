# Commits the work a turn left in a checkout, or none of it. Everything is
# staged and the guard reads what was staged; one violation throws the whole
# turn away, so nothing refused is committed and nothing refused is left in the
# checkout for a later commit to pick up.
class Designs::Committer
  # sha is nil when nothing was committed: the turn was refused (the violations
  # say why) or it changed nothing at all.
  Result = Data.define(:sha, :violations) do
    def ok? = violations.empty?
  end

  def initialize(repo, guard)
    @repo = repo
    @guard = guard
  end

  def commit!(dir, message:)
    # Staging, checking and committing run under one hold of the repo's lock,
    # so what the guard approved is exactly what is committed. The lock is
    # re-entrant: a caller that holds it already is not affected.
    @repo.synchronize do
      violations = @guard.check(@repo.stage_all!(dir))
      if violations.any?
        @repo.discard!(dir)
        Result.new(sha: nil, violations: violations)
      else
        Result.new(sha: @repo.commit!(dir, message: message), violations: [])
      end
    end
  end
end
