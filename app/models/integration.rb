class Integration < ApplicationRecord
  belongs_to :workspace

  validates :provider, presence: true
end
