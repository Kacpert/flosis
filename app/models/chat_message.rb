class ChatMessage < ApplicationRecord
  belongs_to :chat_session
  belongs_to :user, optional: true

  validates :role, presence: true, inclusion: { in: %w[user assistant system] }
  validates :content, presence: true

  # A transcript is a sequence, so the tie has to be broken: a question and its
  # answer can share a created_at, and the engine is then free to hand them
  # back in either order — Postgres and MySQL disagree, and the reply showed
  # above the message it answered.
  scope :ordered, -> { order(:created_at, :id) }
end
