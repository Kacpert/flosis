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

  desc "Install the Puma reverse-proxy .htaccess in app.flosis.com's document root"
  task :app_htaccess do
    on roles(:web) do
      # Static assets are NOT served from this document root — it holds nothing
      # but this file. The `-f` condition never matches, so /assets/* falls
      # through to Puma, which serves it via public_file_server. That avoids
      # needing a symlink to current/public, which shared hosting may refuse to
      # follow.
      htaccess_content = <<~HTACCESS
        RewriteEngine On

        # Force HTTPS here, not in Rails: `assume_ssl = true` makes Rails treat
        # every proxied request as already-secure, so force_ssl never fires.
        RewriteCond %{HTTPS} off
        RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

        # Serve static assets directly
        RewriteCond %{DOCUMENT_ROOT}/%{REQUEST_FILENAME} -f
        RewriteRule ^(.*)$ $1 [L]

        # Proxy everything else to Puma
        RewriteRule ^(.*)$ http://127.0.0.1:3001/$1 [P,L]
      HTACCESS

      execute :mkdir, "-p", fetch(:app_document_root)
      upload! StringIO.new(htaccess_content), "#{fetch(:app_document_root)}/.htaccess"
      # upload! lands the file 0640, which Apache cannot read — it then ignores
      # the rewrite rules entirely and serves a bare 403 from the document root.
      execute :chmod, "644", "#{fetch(:app_document_root)}/.htaccess"

      # Hostido drops a placeholder index.html into every new document root.
      # Leave it and it competes with the proxy for `/`.
      execute :mv, "-n", "#{fetch(:app_document_root)}/index.html",
              "#{fetch(:app_document_root)}/index.html.hostido-placeholder",
              "2>/dev/null || true"
    end
  end

  desc "Retire clar.rubyonsaas.com with a 301 to app.flosis.com. RUN LAST."
  task :legacy_redirect do
    # Deliberately manual and deliberately last: run this only once
    # app.flosis.com is confirmed serving the app. Run it early and you have
    # redirected away the one hostname that still works.
    on roles(:web) do
      htaccess_content = <<~HTACCESS
        RewriteEngine On

        # The application moved to app.flosis.com. Permanent redirect so old
        # bookmarks and links in already-sent email still arrive somewhere real.
        RewriteRule ^(.*)$ https://app.flosis.com/$1 [R=301,L]
      HTACCESS

      upload! StringIO.new(htaccess_content), "#{fetch(:legacy_document_root)}/.htaccess"
      execute :chmod, "644", "#{fetch(:legacy_document_root)}/.htaccess"
    end
  end
end
