# One version of a library entry's text, written once (see LibraryEntry).
class LibraryEntryVersion < ApplicationRecord
  belongs_to :library_entry
  # Nil once the user who wrote it is deleted.
  belongs_to :created_by, class_name: "User", optional: true

  validates :number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :body, presence: true
end
