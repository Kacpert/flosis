lock "~> 3.20"

set :application, "gold"
set :repo_url, "git@github.com:RubyOnSaas-wiki/clar.git"

set :branch, "production"

set :deploy_to, "/home/host420646/domains/clar.rubyonsaas.com/app"

# rbenv
set :rbenv_type, :user
set :rbenv_ruby, File.read(".ruby-version").strip
set :rbenv_prefix, "RBENV_ROOT=#{fetch(:rbenv_path)} RBENV_VERSION=#{fetch(:rbenv_ruby)} #{fetch(:rbenv_path)}/bin/rbenv exec"
set :rbenv_map_bins, %w[rake gem bundle ruby rails puma pumactl]

# Bundler - Bundler 4.x uses config instead of flags
set :bundle_flags, nil
set :bundle_path, -> { shared_path.join("bundle") }
set :bundle_without, %w[development test].join(" ")

# Environment - needed for native gems (libffi, libyaml built from source)
set :default_env, {
  "PATH" => "$HOME/.local/bin:$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH",
  "LD_LIBRARY_PATH" => "$HOME/.local/lib:$LD_LIBRARY_PATH",
  "PKG_CONFIG_PATH" => "$HOME/.local/lib/pkgconfig:$PKG_CONFIG_PATH",
  "TMPDIR" => "$HOME/tmp"
}

# Rails
set :rails_env, "production"
set :migration_role, :app

# Linked files and dirs (shared between releases)
append :linked_files, "config/master.key", ".env"
append :linked_dirs, "log", "tmp/pids", "tmp/cache", "tmp/sockets", "storage", "public/assets"

set :keep_releases, 3

# Shared hosting has noexec on /tmp, use home tmp dir
set :tmp_dir, "/home/host420646/tmp"

# Precompile assets locally and upload to server
set :assets_roles, []  # Disable remote asset precompilation

# Puma
set :puma_bind, "tcp://127.0.0.1:3001"
set :puma_threads, [0, 3]
set :puma_workers, 0
set :puma_init_active_record, true
set :puma_daemonize, true
set :puma_preload_app, false
set :puma_environment, "production"

namespace :puma do
  desc "Start puma as a daemon"
  task :start do
    on roles(:app) do
      within current_path do
        with rails_env: fetch(:rails_env), ld_library_path: "$HOME/.local/lib:$LD_LIBRARY_PATH" do
          # Puma 7 removed --daemon flag, use nohup + background instead
          execute "nohup", "bundle", "exec", "puma", "-C", "config/puma/production.rb", "-e", "production", "> /dev/null 2>&1 &"
        end
      end
    end
  end

  desc "Stop puma"
  task :stop do
    on roles(:app) do
      within current_path do
        pidfile = shared_path.join("tmp/pids/puma.pid")
        if test "[ -f #{pidfile} ]"
          execute :kill, "-TERM", capture(:cat, pidfile)
          execute :rm, "-f", pidfile
        end
      end
    end
  end

  desc "Restart puma"
  task :restart do
    # Puma runs in single mode here (workers 0), where SIGUSR1 is only a
    # phased restart for clustered mode and does NOT reload application code —
    # it just reopens logs, leaving the old release running after a deploy.
    # Do a full stop + start so the new release is actually picked up.
    invoke "puma:stop"
    sleep 1
    invoke "puma:start"
  end
end

namespace :solid_queue do
  desc "Start Solid Queue worker"
  task :start do
    on roles(:app) do
      within current_path do
        with rails_env: fetch(:rails_env), tmpdir: "$HOME/tmp" do
          execute "nohup", "bundle", "exec", "rake", "solid_queue:start", "> #{shared_path}/log/solid_queue.log 2>&1 &"
        end
      end
    end
  end

  desc "Stop Solid Queue worker"
  task :stop do
    on roles(:app) do
      # Match the actual supervisor + worker processes; the previous pattern
      # only caught the rake-launching shell, leaving orphan processes that
      # held DB connections across deploys.
      execute "pkill -f 'solid-queue-' 2>/dev/null || true"
      execute "pkill -f 'solid_queue:start' 2>/dev/null || true"
      execute :sleep, 2
    end
  end

  desc "Restart Solid Queue worker"
  task :restart do
    invoke "solid_queue:stop"
    sleep 2
    invoke "solid_queue:start"
  end
end

namespace :deploy do
  after :publishing, :restart_services do
    invoke "puma:restart"
    invoke "solid_queue:restart"
  end
end
