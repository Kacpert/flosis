# Create demo user and workspace
user = User.find_or_create_by!(email_address: "demo@example.com") do |u|
  u.name = "Demo User"
  u.password = "password123"
  u.password_confirmation = "password123"
end

workspace = Workspace.find_or_create_by!(name: "Demo Workspace")

WorkspaceMembership.find_or_create_by!(user: user, workspace: workspace) do |wm|
  wm.role = :owner
end

# Clients
acme = Client.find_or_create_by!(workspace: workspace, name: "Acme Corp") do |c|
  c.notes = "Main client for web development projects"
end

globex = Client.find_or_create_by!(workspace: workspace, name: "Globex") do |c|
  c.notes = "Design and consulting"
end

# Projects
web_app = Project.find_or_create_by!(workspace: workspace, name: "Web Application") do |p|
  p.client = acme
  p.color = "#3B82F6"
  p.billable = true
  p.hourly_rate_cents = 15000
  p.budget_type = :hours
  p.budget_hours = 200
end

mobile = Project.find_or_create_by!(workspace: workspace, name: "Mobile App") do |p|
  p.client = acme
  p.color = "#10B981"
  p.billable = true
  p.hourly_rate_cents = 17500
end

design = Project.find_or_create_by!(workspace: workspace, name: "Brand Redesign") do |p|
  p.client = globex
  p.color = "#F59E0B"
  p.billable = true
  p.hourly_rate_cents = 12000
  p.budget_type = :money
  p.budget_cents = 500000
end

internal = Project.find_or_create_by!(workspace: workspace, name: "Internal Tools") do |p|
  p.color = "#8B5CF6"
  p.billable = false
end

# Tasks
%w[Frontend Backend API Database].each do |name|
  Task.find_or_create_by!(project: web_app, name: name)
end
%w[iOS Android].each do |name|
  Task.find_or_create_by!(project: mobile, name: name)
end
%w[Logo Website Branding].each do |name|
  Task.find_or_create_by!(project: design, name: name)
end
%w[CI/CD Documentation].each do |name|
  Task.find_or_create_by!(project: internal, name: name)
end

# Tags
tags = {}
[
  { name: "Meeting", color: "#EF4444" },
  { name: "Code Review", color: "#3B82F6" },
  { name: "Bug Fix", color: "#F97316" },
  { name: "Feature", color: "#10B981" },
  { name: "Planning", color: "#8B5CF6" }
].each do |attrs|
  tags[attrs[:name]] = Tag.find_or_create_by!(workspace: workspace, name: attrs[:name]) do |t|
    t.color = attrs[:color]
  end
end

# Sample time entries for the past 2 weeks
web_tasks = web_app.tasks.to_a
mobile_tasks = mobile.tasks.to_a
design_tasks = design.tasks.to_a

entries_data = []
14.downto(0) do |days_ago|
  date = days_ago.days.ago.to_date
  next if date.saturday? || date.sunday?

  # 3-5 entries per day
  rand(3..5).times do |i|
    project = [web_app, mobile, design, internal].sample
    task = project.tasks.to_a.sample
    start_hour = 8 + i * 2
    duration_minutes = rand(30..120)

    entries_data << {
      workspace: workspace,
      user: user,
      project: project,
      task: task,
      description: [
        "Working on #{task&.name || project.name} features",
        "Code review and fixes",
        "Team standup meeting",
        "API integration work",
        "Testing and debugging",
        "Documentation updates",
        "Sprint planning",
        "Design review"
      ].sample,
      started_at: date.to_datetime.change(hour: start_hour, min: rand(0..30)),
      billable: project.billable,
      tag_list: tags.values.sample(rand(0..2))
    }
  end
end

entries_data.each do |data|
  tag_list = data.delete(:tag_list)
  duration = rand(1800..7200)
  started_at = data[:started_at]

  entry = TimeEntry.find_or_initialize_by(
    workspace: data[:workspace],
    user: data[:user],
    started_at: started_at
  )

  next if entry.persisted?

  entry.assign_attributes(data.except(:tag_list))
  entry.stopped_at = started_at + duration.seconds
  entry.save!

  tag_list.each do |tag|
    TimeEntryTag.find_or_create_by!(time_entry: entry, tag: tag)
  end
end

puts "Seed data created!"
puts "Login: demo@example.com / password123"
