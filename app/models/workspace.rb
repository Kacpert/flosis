class Workspace < ApplicationRecord
  has_many :workspace_memberships, dependent: :destroy
  has_many :users, through: :workspace_memberships
  has_many :clients, dependent: :destroy
  has_many :projects, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :time_entries, dependent: :destroy
  has_many :integrations, dependent: :destroy

  validates :name, presence: true
end
