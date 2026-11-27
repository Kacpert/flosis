# Which Claude session a Designs turn runs in (2026-11-27). A thread used to
# resume one session for all its turns, so its context only grew: task 551's
# thread went from 31k to 485k tokens, and after an hour's pause the whole of
# it was written to the cache again. Now:
#
# - the chat's first turn starts the session under the id the chat was made
#   with (:start);
# - a build that answers a plan or a proposal goes on in that session, which
#   holds what the plan read (:resume);
# - any other turn goes on only in a session that is warm (its last turn
#   finished within the cache's hour) and small (its context under 150k
#   tokens), so quick corrections stay quick; otherwise, and for components
#   and resolving turns, which are asked afresh, it starts a new session
#   (:renew), told the thread so far.
#
# A subject that does not renew its sessions (a task's chat, a setup) resumes
# as before. Checks run in sessions of their own and are not asked here.
module Designs::SessionChoice
  WARM_FOR = 55.minutes
  SMALL_BELOW = 150_000
  ALWAYS_NEW = %w[resolve_conflicts components].freeze

  module_function

  def for(turn, renews:, now: Time.current)
    last = turn.chat_session.design_turns.where.not(id: turn.id).where.not(started_at: nil).where.not(kind: "check")
               .order(:id).last
    return :start unless last
    return :resume unless renews
    return :renew if ALWAYS_NEW.include?(turn.kind)
    return :resume if turn.answers_plan?

    warm?(last, now) && small?(last) ? :resume : :renew
  end

  def warm?(turn, now) = turn.finished_at.present? && now - turn.finished_at < WARM_FOR

  # A size not known (a turn from before it was kept) counts as large.
  def small?(turn) = turn.context_tokens.present? && turn.context_tokens < SMALL_BELOW
end
