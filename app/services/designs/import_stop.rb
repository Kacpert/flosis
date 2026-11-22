# Stops an import from its page (Kacper, 2026-11-22: "nie ma przycisku
# stop"). A running import fails as stopped, saying when and by whom; a
# finished import's queue (features retried, answered or added after it)
# fails feature by feature, each saying who stopped it. Either way the Claude
# of each of its turns still under way is killed, by its session id, and the
# turn fails: the browser and git servers go with Claude, whose stdin closes.
# A clone or a sign-in under way ends by itself, and the job then finds the
# import over. Retry (Resume) goes on from where it stopped.
class Designs::ImportStop
  def initialize(setup, user)
    @setup = setup
    @user = user
  end

  # True when something was under way and is stopped now. The unit's claim
  # stays with its job, which lets it go once it has ended the step it was on
  # (Designs::SetupRunJob checks the stop before it starts a turn, lands a
  # feature or approves the import).
  def stop!
    live = false
    stopped = @setup.with_lock do
      live = @setup.unit_live?
      if @setup.running?
        @setup.update!(status: "failed", error: nil, stopped_at: Time.current, stopped_by: @user, paused_until: nil)
        fail_pending!
        true
      elsif @setup.follow_up?
        fail_pending!
        true
      else
        false
      end
    end
    stop_turns!(live) if stopped
    stopped
  end

  private

  def message = format(DesignSetup::STOPPED, @user.name)

  # What it had to do fails, saying who stopped it: Resume puts it back.
  def fail_pending!
    @setup.features.pending.find_each do |feature|
      feature.update!(status: "failed", stage: nil, finished_at: Time.current, error: message)
    end
  end

  # Each turn under way is asked to stop: its job checks every 2 s, also
  # after a CLI it restarted (Designs::TurnJob#follow), and .fail_stale!
  # fails it once nobody did. A turn whose job is gone (no live unit) has its
  # Claude killed as well, by its session id.
  def stop_turns!(live)
    DesignTurn.joins(:chat_session).includes(:chat_session).where(status: DesignTurn::ACTIVE)
              .where(chat_sessions: { design_setup_id: @setup.id }).find_each do |turn|
      turn.update!(stop_requested_at: Time.current, stop_requested_by: @user.name)
      Designs::SetupRunJob.killer.call(turn.chat_session.claude_session_id) unless live
    end
  end
end
