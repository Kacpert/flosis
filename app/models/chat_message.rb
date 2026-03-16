class ChatMessage < ApplicationRecord
  belongs_to :chat_session

  validates :role, presence: true, inclusion: { in: %w[user assistant system] }
  validates :content, presence: true

  scope :ordered, -> { order(:created_at) }
end
