class TimeEntryTag < ApplicationRecord
  belongs_to :time_entry
  belongs_to :tag
end
