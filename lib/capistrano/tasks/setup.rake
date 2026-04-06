namespace :setup do
  desc "Create shared directories and files on server"
  task :init do
    on roles(:app) do
      execute :mkdir, "-p", "#{shared_path}/config"
      execute :mkdir, "-p", "#{shared_path}/log"
      execute :mkdir, "-p", "#{shared_path}/tmp/pids"
      execute :mkdir, "-p", "#{shared_path}/tmp/cache"
      execute :mkdir, "-p", "#{shared_path}/tmp/sockets"
      execute :mkdir, "-p", "#{shared_path}/storage"
      execute :mkdir, "-p", "#{shared_path}/public/assets"
    end
  end

  desc "Upload master.key to server"
  task :upload_master_key do
    on roles(:app) do
      upload! "config/master.key", "#{shared_path}/config/master.key"
    end
  end

  desc "Upload .env to server"
  task :upload_env do
    on roles(:app) do
      upload! ".env.production", "#{shared_path}/.env"
    end
  end

  desc "Setup .htaccess reverse proxy"
  task :htaccess do
    on roles(:web) do
      htaccess_content = <<~HTACCESS
        RewriteEngine On

        # Serve static assets directly
        RewriteCond %{DOCUMENT_ROOT}/%{REQUEST_FILENAME} -f
        RewriteRule ^(.*)$ $1 [L]

        # Proxy everything else to Puma
        RewriteRule ^(.*)$ http://127.0.0.1:3001/$1 [P,L]
      HTACCESS

      upload! StringIO.new(htaccess_content), "/home/host420646/domains/clar.rubyonsaas.com/public_html/.htaccess"
    end
  end
end
