namespace :db do
  desc "Load schema into the database (first deploy only)"
  task :schema_load do
    on roles(:db) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          execute :bundle, "exec", "rails", "db:schema:load"
        end
      end
    end
  end
end
