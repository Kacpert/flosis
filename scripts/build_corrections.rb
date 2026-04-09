#!/usr/bin/env ruby
# Build a corrections file from CSV data
# Run locally: ruby lib/build_corrections.rb > /tmp/corrections.csv

require "csv"
require "time"

csv_dir = File.expand_path("~/Downloads/exported_data")

puts "employee,project,duration_min,description,correct_date,start_hour,start_min"

Dir.glob(File.join(csv_dir, "*.csv")).sort.each do |file|
  CSV.foreach(file, headers: true) do |row|
    date = row["Date"]
    employee = row["Employee"]
    project = row["Project"]
    start_time_str = row["Start time"]
    duration_min = row["Duration (minutes)"].to_i
    notes = row["Notes"].to_s.strip

    # Parse Start time with timezone, convert to UTC
    parsed_start = Time.parse(start_time_str).utc
    start_hour = parsed_start.hour
    start_min = parsed_start.min

    puts CSV.generate_line([
      employee,
      project,
      duration_min,
      notes,
      date,
      start_hour,
      start_min
    ]).strip
  end
end
