# The marketing site at flosis.com is plain static HTML in its own document
# root — no Rails, no Puma. It ships on its own schedule (new landing versions
# arrive from design), so this is deliberately NOT hooked into `deploy`. Run it
# by hand when the page actually changes:
#
#   cap production deploy:landing
#
namespace :deploy do
  desc "Upload the static marketing landing page to flosis.com"
  task :landing do
    target = fetch(:landing_document_root)

    on roles(:web) do
      execute :mkdir, "-p", target
    end

    on roles(:web) do |host|
      port = host.port || host.netssh_options[:port] || 22
      run_locally do
        # No --delete: this is a live document root, and nuking anything the
        # panel put there (verification files, cert challenges) is not worth
        # the tidiness.
        execute "rsync -avz -e 'ssh -p #{port}' marketing/ #{host.user}@#{host.hostname}:#{target}/"
      end
    end
  end
end
