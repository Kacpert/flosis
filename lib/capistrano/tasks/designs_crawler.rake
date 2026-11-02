namespace :setup do
  # The setup run's browser tools (lib/designs_crawler: the sign-in and the MCP
  # browser its turns drive) live outside the releases, in
  # shared/designs_crawler, beside their node_modules and with Chromium in the
  # user's cache. DESIGNS_CRAWLER_DIR in the server's .env points there, and
  # PLAYWRIGHT_BROWSERS_PATH at the cache. Node writes temp files under
  # $HOME/tmp: the host's /tmp is small. The tests stay behind.
  desc "Install the Designs setup's browser tools (Node + Playwright + Chromium) in shared/designs_crawler"
  task :designs_crawler do
    on roles(:app) do
      dir = "#{shared_path}/designs_crawler"
      execute :mkdir, "-p", dir, "$HOME/tmp"
      execute :rm, "-f", "#{dir}/crawl.mjs"
      Dir.glob("lib/designs_crawler/*.mjs").each { |file| upload! file, "#{dir}/#{File.basename(file)}" }
      upload! "lib/designs_crawler/package.json", "#{dir}/package.json"
      lock = "lib/designs_crawler/package-lock.json"
      upload! lock, "#{dir}/package-lock.json" if File.exist?(lock)
      within dir do
        with tmpdir: "$HOME/tmp", playwright_browsers_path: "$HOME/.cache/ms-playwright" do
          File.exist?(lock) ? execute(:npm, "ci", "--omit=dev", "--no-audit", "--no-fund") : execute(:npm, "install", "--no-audit", "--no-fund")
          execute :npx, "playwright", "install", "chromium"
        end
      end
    end
  end
end
