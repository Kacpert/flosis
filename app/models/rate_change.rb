class RateChange < ApplicationRecord
  belongs_to :project_membership
  belongs_to :changed_by, class_name: "User", optional: true
end
