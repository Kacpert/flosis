# When the person who started a setup was told it finished ("Designs ready ·
# <project> @ master"), so they are told once.
class AddNotifiedAtToDesignSetups < ActiveRecord::Migration[8.1]
  def change
    add_column :design_setups, :notified_at, :datetime
  end
end
