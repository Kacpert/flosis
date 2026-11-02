class BackfillWorkshopPipeline < ActiveRecord::Migration[8.1]
  class MTask < ActiveRecord::Base; self.table_name = "tasks"; end
  class MBrief < ActiveRecord::Base; self.table_name = "briefs"; end
  class MChatSession < ActiveRecord::Base; self.table_name = "chat_sessions"; end

  def up
    ids = MBrief.distinct.pluck(:task_id) |
          MChatSession.where(purpose: "brief").distinct.pluck(:task_id)
    MTask.where(id: ids).find_each do |t|
      briefed = MBrief.where(task_id: t.id, status: "briefed").exists?
      t.update_columns(in_pipeline: true,
                       workshop_stage: briefed ? "details" : "briefing",
                       pipeline_entered_at: t.pipeline_entered_at || t.created_at)
    end
  end

  def down; end
end
