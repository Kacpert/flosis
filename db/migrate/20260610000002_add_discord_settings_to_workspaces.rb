class AddDiscordSettingsToWorkspaces < ActiveRecord::Migration[8.1]
  def change
    add_column :workspaces, :discord_user_token, :string
    add_column :workspaces, :discord_channel_id, :string
  end
end
