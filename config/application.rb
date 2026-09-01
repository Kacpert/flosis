require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Gold
  class Application < Rails::Application
    # Ensure active_storage.queues is initialized before load_defaults
    # (workaround for Rails 8.1 on some platforms — load_defaults calls
    # config.active_storage.queues.analysis = ..., which crashes if queues
    # is nil). Set queues to an OrderedOptions so attribute assignment works,
    # without replacing the whole active_storage config object.
    if config.respond_to?(:active_storage) && config.active_storage.respond_to?(:queues) && config.active_storage.queues.nil?
      config.active_storage.queues = ActiveSupport::OrderedOptions.new
    end

    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # lib/mcp holds standalone MCP server executables (lib/mcp/lit_server.rb).
    # They run as their own process — never inside this one — so they must stay
    # out of the autoloader, which would otherwise demand Zeitwerk-shaped
    # constant names of a plain script and break eager loading in production.
    config.autoload_lib(ignore: %w[assets tasks mcp])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # The team is in Poland; display and interpret all times in Warsaw time.
    # ActiveRecord still stores timestamps in UTC; this affects display, parsing,
    # Time.current, and recurring-job schedule evaluation (so cron entries below
    # use local Warsaw hours).
    config.time_zone = "Warsaw"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
