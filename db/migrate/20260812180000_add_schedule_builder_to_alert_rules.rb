# Replaces the fixed `frequency` enum (daily/weekdays/mwf/weekly/hourly) with a
# composable schedule: a mode (daily · specific days · every N hours), the
# weekdays it may run on, and an optional time window for the interval mode.
#
# NOTHING IS DROPPED — `frequency` stays on the table (and is kept in sync as a
# legacy mirror by AlertRule) so existing rows and any older code path keep
# working. The backfill below translates each existing frequency into the
# equivalent new-schedule fields, so every rule keeps running on exactly the
# cadence it had before.
class AddScheduleBuilderToAlertRules < ActiveRecord::Migration[8.1]
  DAYS_FOR_FREQUENCY = {
    "daily"    => "Mon,Tue,Wed,Thu,Fri,Sat,Sun",
    "weekdays" => "Mon,Tue,Wed,Thu,Fri",
    "mwf"      => "Mon,Wed,Fri",
    "weekly"   => "Mon",
    "hourly"   => "Mon,Tue,Wed,Thu,Fri,Sat,Sun"
  }.freeze

  def up
    add_column :alert_rules, :schedule_mode, :string, default: "daily", null: false
    add_column :alert_rules, :schedule_days, :string, default: "Mon,Tue,Wed,Thu,Fri,Sat,Sun", null: false
    add_column :alert_rules, :interval_hours, :integer, default: 4, null: false
    add_column :alert_rules, :window_enabled, :boolean, default: false, null: false
    add_column :alert_rules, :window_from, :string, default: "09:00", null: false
    add_column :alert_rules, :window_to, :string, default: "18:00", null: false

    DAYS_FOR_FREQUENCY.each do |frequency, days|
      mode =
        case frequency
        when "hourly" then "interval"
        when "daily"  then "daily"
        else "days"
        end

      updates = { schedule_mode: mode, schedule_days: days }
      # "Every hour" becomes an unbounded 1-hour interval — same behaviour.
      updates.merge!(interval_hours: 1, window_enabled: false) if frequency == "hourly"

      execute <<~SQL.squish
        UPDATE alert_rules
           SET #{updates.map { |k, v| "#{k} = #{connection.quote(v)}" }.join(', ')}
         WHERE frequency = #{connection.quote(frequency)}
      SQL
    end
  end

  def down
    remove_column :alert_rules, :schedule_mode
    remove_column :alert_rules, :schedule_days
    remove_column :alert_rules, :interval_hours
    remove_column :alert_rules, :window_enabled
    remove_column :alert_rules, :window_from
    remove_column :alert_rules, :window_to
  end
end
