class ChatMessage < ApplicationRecord
  belongs_to :chat_session
  belongs_to :user, optional: true

  # What a Designs chat marks a message as, for its screen to draw it apart:
  # Claude's summary of a turn, a context it added, a question it left open,
  # an error, or a note from Flosis itself. A design thread (Workshop Designs
  # v2) adds the task description's diff, the merges that came in from master,
  # and a request Flosis made on the person's behalf, which is not shown.
  # Other chats leave it empty.
  KINDS = %w[summary context missing error system diff master request].freeze

  validates :role, presence: true, inclusion: { in: %w[user assistant system] }
  validates :content, presence: true
  validates :kind, inclusion: { in: KINDS }, allow_nil: true

  # A transcript is a sequence, so the tie has to be broken: a question and its
  # answer can share a created_at, and the engine is then free to hand them
  # back in either order — Postgres and MySQL disagree, and the reply showed
  # above the message it answered.
  scope :ordered, -> { order(:created_at, :id) }
end
