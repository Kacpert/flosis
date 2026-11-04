# When a person last opened an import's page (Designs imports): the Imports
# line stays lit for them while an import has settled since.
class DesignImportView < ApplicationRecord
  belongs_to :design_setup
  belongs_to :user

  validates :seen_at, presence: true
end
