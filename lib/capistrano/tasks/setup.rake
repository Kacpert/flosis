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

  desc "Install the .htaccess of the Designs preview host (needs DESIGNS_PREVIEW_DOCUMENT_ROOT)"
  task :designs_preview_htaccess do
    root = fetch(:designs_preview_document_root).to_s.strip.chomp("/")
    if root.empty?
      abort "setup:designs_preview_htaccess needs the preview domain's document root, and " \
            "designs_preview_document_root is not set. Run it as: " \
            "DESIGNS_PREVIEW_DOCUMENT_ROOT=/home/host420646/domains/<domain>/public_html " \
            "cap production setup:designs_preview_htaccess"
    end

    # This task replaces .htaccess and moves index.html aside. Pointed at another
    # hostname's root it would take that site down.
    other = %i[app_document_root landing_document_root legacy_document_root]
            .find { |name| fetch(name).to_s.chomp("/") == root }
    if other
      abort "designs_preview_document_root (#{root}) is the same folder as #{other}, another hostname's: " \
            "this task would replace its .htaccess and move its index.html aside. " \
            "Use the preview domain's own document root."
    end

    # Only this origin may put a preview in a frame (the Designs screen); Jira
    # opens links top-level. It goes into a quoted header value, so it must be
    # one bare https origin: anything else would widen the policy or break the
    # file, and the preview host with it.
    frame_ancestor = fetch(:designs_preview_frame_ancestor, "https://app.flosis.com").to_s
    unless frame_ancestor.match?(%r{\Ahttps://[A-Za-z0-9.-]+(:\d+)?\z})
      abort "designs_preview_frame_ancestor (#{frame_ancestor.inspect}) must be one https origin, " \
            "such as https://app.flosis.com."
    end

    # Single-quoted heredoc: the backslashes in the patterns stay as written.
    rules = <<~'HTACCESS'
      Options -Indexes -ExecCGI -Includes
      DirectoryIndex index.html
      # Designs may load ES modules, and Apache's own types may not know .mjs.
      AddType text/javascript .mjs

      RewriteEngine On
      RewriteCond %{HTTPS} off
      RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

      # Half-published and replaced copies are never served.
      RewriteRule (^|/)\.(staging|old)- - [F,L]

      # The publisher strips scripts from what it publishes. Anything that got past it
      # is still refused here: no file with a script extension anywhere in its name
      # (shell.php.html) is ever served.
      <FilesMatch "(?i)\.(php[0-9]?|phtml|phar|pht|phps|cgi|fcgi|pl|py|sh|asp|aspx|jsp|shtml|shtm|stm)(\.|$)">
        Require all denied
      </FilesMatch>
    HTACCESS

    headers = <<~HTACCESS
      <IfModule mod_headers.c>
        # The project token is in every path: never hand it to another site.
        Header always set Referrer-Policy "no-referrer"
        Header always set X-Robots-Tag "noindex, nofollow"
        Header always set X-Content-Type-Options "nosniff"
        # Published files change in place: a browser asks again before it shows one.
        Header always set Cache-Control "no-cache"
        # HTTPS only, for a year: the token in the path never travels in the clear.
        Header always set Strict-Transport-Security "max-age=31536000"
        Header always set Content-Security-Policy "frame-ancestors #{frame_ancestor}"
      </IfModule>
    HTACCESS
    htaccess_content = "#{rules}\n#{headers}"

    on roles(:web) do
      # No mkdir: the root is made when the domain is added in the Hostido panel,
      # and a mistyped path should fail here rather than leave a stray folder.
      upload! StringIO.new(htaccess_content), "#{root}/.htaccess"
      # upload! lands the file 0640, which Apache cannot read (see app_htaccess).
      execute :chmod, "644", "#{root}/.htaccess"

      # Hostido's placeholder index.html, as in app_htaccess.
      execute :mv, "-n", "#{root}/index.html", "#{root}/index.html.hostido-placeholder",
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
