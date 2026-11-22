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

  # True when something was under way and is stopped now.
  def stop!
    stopped = @setup.with_lock do
      if @setup.running?
        @setup.update!(status: "failed", error: nil, stopped_at: Time.current, stopped_by: @user,
                       unit_job_id: nil, unit_deadline_at: nil, paused_until: nil)
      elsif @setup.follow_up?
        @setup.features.pending.find_each do |feature|
          feature.update!(status: "failed", stage: nil, finished_at: Time.current, error: message)
        end
        true
      else
        false
      end
    end
    stop_turns! if stopped
    stopped
  end

  private

  def message = format(DesignSetup::STOPPED, @user.name)

  def stop_turns!
    DesignTurn.joins(:chat_session).includes(:chat_session).where(status: DesignTurn::ACTIVE)
              .where(chat_sessions: { design_setup_id: @setup.id }).find_each do |turn|
      Designs::SetupRunJob.killer.call(turn.chat_session.claude_session_id)
      turn.fail!(message)
    end
  end
end
