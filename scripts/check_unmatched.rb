require "csv"
require "time"

IMPORT_WINDOW_START = Time.utc(2026, 4, 6, 11, 20, 0)
IMPORT_WINDOW_END = Time.utc(2026, 4, 6, 11, 21, 0)

imported = TimeEntry.where("created_at >= ? AND created_at < ?", IMPORT_WINDOW_START, IMPORT_WINDOW_END)
  .includes(:user, :project).to_a

entries_by_key = {}
imported.each do |entry|
  key = [entry.user.name, entry.project.name, entry.duration_seconds / 60, entry.description.to_s.strip]
  entries_by_key[key] ||= []
  entries_by_key[key] << entry
end

csv_data = STDIN.read
matched_keys = Set.new

CSV.parse(csv_data, headers: true).each do |row|
  key = [row["employee"], row["project"], row["duration_min"].to_i, row["description"].to_s.strip]
  if entries_by_key[key] && entries_by_key[key].any?
    entries_by_key[key].shift
    entries_by_key.delete(key) if entries_by_key[key].empty?
    matched_keys << key
  end
end

# Show remaining unmatched DB entries
remaining = entries_by_key.values.flatten
puts "Unmatched DB entries: #{remaining.size}"
remaining.first(20).each do |e|
  puts "  DB: user=#{e.user.name} proj=#{e.project.name} dur=#{e.duration_seconds/60}min started=#{e.started_at} desc=#{e.description.to_s[0..60].inspect}"
end
