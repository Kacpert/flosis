class AddMetadataToPrReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_reviews, :pr_title, :string
    add_column :pr_reviews, :pr_author, :string
    add_column :pr_reviews, :pr_branch, :string
    add_column :pr_reviews, :pr_url, :string
    add_column :pr_reviews, :comment_count, :integer
    add_column :pr_reviews, :outcome, :string, default: "pending", null: false

    add_column :workspaces, :pr_poll_minutes, :integer, default: 7, null: false
    add_column :workspaces, :pr_polled_at, :datetime
  end
end
