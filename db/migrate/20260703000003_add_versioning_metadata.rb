class AddVersioningMetadata < ActiveRecord::Migration[8.1]
  class MBrief < ActiveRecord::Base; self.table_name = "briefs"; end
  class MDraft < ActiveRecord::Base; self.table_name = "task_drafts"; end

  def change
    add_column :briefs, :origin, :string, default: "ai", null: false
    add_column :briefs, :current, :boolean, default: false, null: false
    add_column :briefs, :edited_at, :datetime
    add_column :task_drafts, :origin, :string, default: "ai", null: false
    add_column :task_drafts, :current, :boolean, default: false, null: false
    add_column :task_drafts, :edited_at, :datetime
    add_column :task_drafts, :version, :integer
    add_column :task_drafts, :pushed_at, :datetime
    # "Save locally" flags read by the SAVED LOCALLY badge (Task 4.3)
    add_column :tasks, :brief_saved_locally_at, :datetime
    add_column :tasks, :detail_saved_locally_at, :datetime
    # Plain (non-partial) indexes — MySQL has no partial indexes; exclusivity of
    # `current` is enforced by make_current!'s transaction, not the DB.
    add_index :briefs, [:task_id, :current]
    add_index :task_drafts, [:task_id, :source, :current]
    reversible do |dir|
      dir.up do
        # Portable Ruby backfill (must run on PG dev/test AND MySQL prod)
        MDraft.distinct.pluck(:task_id, :source).each do |task_id, source|
          MDraft.where(task_id: task_id, source: source).order(:created_at)
                .each_with_index { |d, i| d.update_columns(version: i + 1) }
        end
        MBrief.group(:task_id).maximum(:version).each do |task_id, max_v|
          MBrief.where(task_id: task_id, version: max_v).update_all(current: true)
        end
      end
    end
  end
end
