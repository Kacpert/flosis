class Client < ApplicationRecord
  belongs_to :workspace
  has_many :projects, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :workspace_id }

  scope :active, -> { where(archived: false) }
  scope :archived, -> { where(archived: true) }
end
