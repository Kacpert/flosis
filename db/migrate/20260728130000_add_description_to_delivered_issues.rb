class AddDescriptionToDeliveredIssues < ActiveRecord::Migration[8.1]
  def change
    # Plain-text Jira description (flattened from ADF), so delivered issues that
    # have no local Task can still be AI-estimated from their title + description.
    add_column :delivered_issues, :description, :text
  end
end
