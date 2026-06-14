class Workspace < ApplicationRecord
  has_many :workspace_memberships, dependent: :destroy
  has_many :users, through: :workspace_memberships
  has_many :clients, dependent: :destroy
  has_many :projects, dependent: :destroy
  has_many :tags, dependent: :destroy
  has_many :time_entries, dependent: :destroy
  has_many :integrations, dependent: :destroy
  has_many :chat_sessions, dependent: :destroy
  has_many :feedback_meetings, dependent: :destroy

  has_many :holiday_requests, dependent: :destroy
  has_many :holiday_balance_entries, dependent: :destroy
  has_many :discord_reminder_recipients, dependent: :destroy
  has_many :pr_reviews, dependent: :delete_all

  validates :name, presence: true
end
