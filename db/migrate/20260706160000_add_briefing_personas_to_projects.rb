class AddBriefingPersonasToProjects < ActiveRecord::Migration[8.1]
  def change
    # Human-written personas / product perspective for the briefing PO chat.
    # Appended as its own section in the briefing prompt (separate from the
    # auto-scanned features_summary and the generic context_info).
    add_column :projects, :briefing_personas, :text
  end
end
