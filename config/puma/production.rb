app_dir = File.expand_path("../../..", __FILE__)
# Resolve the real path first (follows symlinks), then navigate to shared
real_app_dir = File.realpath(app_dir)
# real_app_dir = /home/.../app/releases/TIMESTAMP
# Go up 2 levels to get /home/.../app, then into shared
shared_dir = File.join(File.expand_path("../..", real_app_dir), "shared")

directory app_dir
environment "production"

# Bind to localhost port for reverse proxy
bind "tcp://127.0.0.1:3001"

threads 0, 3
workers 0

pidfile "#{shared_dir}/tmp/pids/puma.pid"
state_path "#{shared_dir}/tmp/pids/puma.state"
stdout_redirect "#{shared_dir}/log/puma.stdout.log", "#{shared_dir}/log/puma.stderr.log", true

preload_app!
