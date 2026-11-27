# The largest context a design turn's own requests reached, in tokens
# (2026-11-27): whether the thread's next message may resume its Claude
# session or starts a new one (Designs::SessionChoice).
class AddContextTokensToDesignTurns < ActiveRecord::Migration[8.1]
  def change
    add_column :design_turns, :context_tokens, :integer
  end
end
