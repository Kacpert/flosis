class PrReview < ApplicationRecord
  belongs_to :workspace

  validates :pr_number, presence: true, uniqueness: { scope: :workspace_id }
end
