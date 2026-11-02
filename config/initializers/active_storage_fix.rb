# Workaround for Rails 8.1 eager loading order issue where
# ActiveStorage::Blob tries to call has_one_attached before
# the ActiveStorage::Attached::Model concern and Reflection
# extension are included into ActiveRecord::Base.
Rails.application.config.before_eager_load do
  require "active_storage/attached"
  require "active_storage/reflection"

  unless ActiveRecord::Base < ActiveStorage::Attached::Model
    ActiveRecord::Base.include ActiveStorage::Attached::Model
  end

  unless ActiveRecord::Base < ActiveStorage::Reflection::ActiveRecordExtensions
    ActiveRecord::Base.include ActiveStorage::Reflection::ActiveRecordExtensions
    ActiveRecord::Reflection.singleton_class.prepend(ActiveStorage::Reflection::ReflectionExtension)
  end
end
