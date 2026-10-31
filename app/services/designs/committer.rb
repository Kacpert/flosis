# Commits the work a turn left in a checkout, or none of it. Everything is
# staged and the guard reads what was staged; one violation throws the whole
# turn away, so nothing refused is committed and nothing refused is left in the
# checkout for a later commit to pick up.
class Designs::Committer
  # sha is nil when nothing was committed: the turn was refused (the violations
  # say why) or it changed nothing at all.
  Result = Data.define(:sha, :violations) do
    def ok? = violations.empty?

    # What was refused, as the people using the project are told it: each
    # path with its rule. A violation never carries the text that broke the
    # rule, so this repeats nothing that was refused.
    def refusal = violations.map { |violation| "#{violation.path} #{violation.reason}" }.join("; ")
  end

  # Every page loads the runtime, and ensure_clone! refuses a master without
  # it as somebody else's repository: one commit that dropped it, once
  # approved, would lock the project out of its own design repo.
  NO_RUNTIME = Designs::LeakGuard::Violation.new(path: Designs::Repo::RUNTIME, reason: "would delete the design runtime")

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
      violations += [ NO_RUNTIME ] unless @repo.indexed?(dir, Designs::Repo::RUNTIME)
      if violations.any?
        @repo.discard!(dir)
        Result.new(sha: nil, violations: violations)
      else
        Result.new(sha: @repo.commit!(dir, message: message), violations: [])
      end
    end
  end
end
