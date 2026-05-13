require "active_support/lazy_load_hooks"

# Manually load storage.yml and set the ActiveStorage service.
# Workaround: on Rails 8.1.x in this app's boot path, the AS engine's normal
# load_configurations step doesn't populate config.active_storage.service_configurations,
# leaving ActiveStorage::Blob.service nil at runtime.
ActiveSupport.on_load(:active_storage_blob) do
  storage_yml = Rails.root.join("config/storage.yml")
  next unless storage_yml.exist?

  configs = ActiveSupport::ConfigurationFile.parse(storage_yml)
  service_name = Rails.application.config.active_storage.service

  if service_name && configs[service_name.to_s]
    ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(configs)
    ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch(service_name)
  end
end
