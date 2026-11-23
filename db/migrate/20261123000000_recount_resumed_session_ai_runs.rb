# Kacper (2026-11-23): a resumed Claude session reports the whole session so
# far, and each run of one was recorded with that whole report, so a thread's
# design turn was counted again with every later message. Each such run gets
# its own share (AiRun::Recorder.recount_sessions!); the CLI's reports stay as
# they came, so nothing is lost and a recount changes nothing more.
class RecountResumedSessionAiRuns < ActiveRecord::Migration[8.1]
  def up
    say "AI runs recounted: #{AiRun::Recorder.recount_sessions!}"
  end

  def down
  end
end
