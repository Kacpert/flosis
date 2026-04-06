app_dir = File.expand_path("../../..", __FILE__)
shared_dir = File.expand_path("../../../../shared", __FILE__)

directory app_dir
environment "production"

# Bind to localhost port for reverse proxy
bind "tcp://127.0.0.1:3001"

threads 0, 3
workers 0

pidfile "#{shared_dir}/tmp/pids/puma.pid"
state_path "#{shared_dir}/tmp/pids/puma.state"
stdout_redirect "#{shared_dir}/log/puma.stdout.log", "#{shared_dir}/log/puma.stderr.log", true

# Run Solid Queue inside Puma
plugin :solid_queue

preload_app!
