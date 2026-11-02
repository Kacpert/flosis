namespace :puma do
  desc "Install cron watchdog to keep Puma alive"
  task :install_watchdog do
    on roles(:app) do
      watchdog_script = <<~BASH
        #!/bin/bash
        source ~/.bash_profile
        PIDFILE=#{shared_path}/tmp/pids/puma.pid
        APP_DIR=#{current_path}

        if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
          exit 0
        fi

        cd "$APP_DIR"
        RBENV_ROOT=$HOME/.rbenv RBENV_VERSION=#{fetch(:rbenv_ruby)} $HOME/.rbenv/bin/rbenv exec bundle exec puma -C config/puma/production.rb -e production --daemon
      BASH

      upload! StringIO.new(watchdog_script), "#{shared_path}/puma_watchdog.sh"
      execute :chmod, "+x", "#{shared_path}/puma_watchdog.sh"

      # Add cron job (every 5 minutes)
      cron_line = "*/5 * * * * #{shared_path}/puma_watchdog.sh >> #{shared_path}/log/puma_watchdog.log 2>&1"
      execute :bash, "-c", %Q(crontab -l 2>/dev/null | grep -v puma_watchdog | { cat; echo '#{cron_line}'; } | crontab -)
    end
  end
end
