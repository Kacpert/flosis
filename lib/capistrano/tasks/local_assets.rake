namespace :deploy do
  desc "Precompile assets locally and upload"
  task :compile_assets_locally do
    run_locally do
      execute "RAILS_ENV=production bundle exec rake assets:precompile"
    end

    on roles(:web) do |host|
      run_locally do
        execute "rsync -avz --delete -e 'ssh -p #{host.port}' public/assets/ #{host.user}@#{host.hostname}:#{shared_path}/public/assets/"
      end
    end

    run_locally do
      execute "rm -rf public/assets"
    end
  end

  before "deploy:symlink:release", "deploy:compile_assets_locally"
end
