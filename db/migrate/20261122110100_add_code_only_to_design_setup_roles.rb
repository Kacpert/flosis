# Designs imports (Kacper, 2026-11-22: "nie miał credentiali ale może na
# podstawie repo postarać się odzwierciedlić bez otwierania strony"): a
# context can have no login and be built from the app's code, and a feature
# records the contexts it was built from the code for.
class AddCodeOnlyToDesignSetupRoles < ActiveRecord::Migration[8.1]
  def change
    add_column :design_setup_roles, :code_only, :boolean, default: false, null: false
    # A code-only context has no login: the model asks for one only when it
    # signs in.
    change_column_null :design_setup_roles, :login_url, true
    change_column_null :design_setup_roles, :username, true
    change_column_null :design_setup_roles, :password, true
    add_column :design_setup_features, :from_code, :json
  end
end
