require "csv"
require "time"

# Read corrections from STDIN (piped from local machine)
# Format: employee,project,duration_min,description,correct_date,start_hour,start_min

IMPORT_WINDOW_START = Time.utc(2026, 4, 6, 11, 20, 0)
IMPORT_WINDOW_END = Time.utc(2026, 4, 6, 11, 21, 0)

# Load all imported entries
imported = TimeEntry.where("created_at >= ? AND created_at < ?", IMPORT_WINDOW_START, IMPORT_WINDOW_END)
  .includes(:user, :project).to_a
puts "Loaded #{imported.size} imported entries"

# Name mapping: CSV names -> DB names
NAME_MAP = {
  "Kacper Tarchała" => "Kacper",
  "Paweł Kremienowski" => "Paweł Kremienowski"
}.freeze

def normalize_name(csv_name)
  NAME_MAP[csv_name] || csv_name
end

# Index by [user_name, project_name, duration_min, description]
entries_by_key = {}
imported.each do |entry|
  key = [entry.user.name, entry.project.name, entry.duration_seconds / 60, entry.description.to_s.strip]
  entries_by_key[key] ||= []
  entries_by_key[key] << entry
end

updated = 0
not_matched = 0
already_correct = 0

CSV.parse(STDIN.read, headers: true).each do |row|
  employee = row["employee"]
  project = row["project"]
  duration_min = row["duration_min"].to_i
  description = row["description"].to_s.strip
  correct_date = Date.parse(row["correct_date"])
  start_hour = row["start_hour"].to_i
  start_min = row["start_min"].to_i

  key = [normalize_name(employee), project, duration_min, description]
  candidates = entries_by_key[key]

  unless candidates && candidates.any?
    not_matched += 1
    next
  end

  entry = candidates.shift
  entries_by_key.delete(key) if candidates.empty?

  correct_started_at = Time.utc(correct_date.year, correct_date.month, correct_date.day, start_hour, start_min)
  correct_stopped_at = correct_started_at + (duration_min * 60)

  if entry.started_at == correct_started_at && entry.stopped_at == correct_stopped_at
    already_correct += 1
    next
  end

  entry.update_columns(
    started_at: correct_started_at,
    stopped_at: correct_stopped_at,
    duration_seconds: duration_min * 60
  )
  updated += 1
end

puts "Updated: #{updated}"
puts "Already correct: #{already_correct}"
puts "Not matched: #{not_matched}"
