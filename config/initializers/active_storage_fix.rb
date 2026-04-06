# Workaround for Rails 8.1 eager loading order issue where
# ActiveStorage::Blob tries to call has_one_attached before
# the ActiveStorage::Attached::Model concern is included into
# ActiveRecord::Base.
Rails.application.config.before_eager_load do
  require "active_storage/attached"
  unless ActiveRecord::Base < ActiveStorage::Attached::Model
    ActiveRecord::Base.include ActiveStorage::Attached::Model
  end
end
