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
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
