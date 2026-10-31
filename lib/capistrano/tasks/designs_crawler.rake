namespace :setup do
  # The setup run's crawler (lib/designs_crawler) lives outside the releases,
  # in shared/designs_crawler, beside its node_modules and with Chromium in
  # the user's cache. DESIGNS_CRAWLER_DIR in the server's .env points there.
  # Node writes temp files under $HOME/tmp: the host's /tmp is small.
  desc "Install the Designs setup crawler (Node + Playwright + Chromium) in shared/designs_crawler"
  task :designs_crawler do
    on roles(:app) do
      dir = "#{shared_path}/designs_crawler"
      execute :mkdir, "-p", dir, "$HOME/tmp"
      %w[package.json crawl.mjs].each { |file| upload! "lib/designs_crawler/#{file}", "#{dir}/#{file}" }
      lock = "lib/designs_crawler/package-lock.json"
      upload! lock, "#{dir}/package-lock.json" if File.exist?(lock)
      within dir do
        with tmpdir: "$HOME/tmp", playwright_browsers_path: "$HOME/.cache/ms-playwright" do
          execute :npm, "install", "--no-audit", "--no-fund"
          execute :npx, "playwright", "install", "chromium"
        end
      end
    end
  end
end
