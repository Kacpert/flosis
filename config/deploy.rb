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
        with rails_env: fetch(:rails_env) do
          execute :bundle, "exec", "puma", "-C", "config/puma/production.rb", "-e", "production", "--daemon"
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
    on roles(:app) do
      within current_path do
        pidfile = shared_path.join("tmp/pids/puma.pid")
        if test "[ -f #{pidfile} ]" and test("kill -0 $(cat #{pidfile}) 2>/dev/null")
          execute :kill, "-USR1", capture(:cat, pidfile)
        else
          invoke "puma:start"
        end
      end
    end
  end
end

namespace :deploy do
  after :publishing, :restart_puma do
    invoke "puma:restart"
  end
end
