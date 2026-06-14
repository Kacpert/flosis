class AddEnqueuedShaToPrReviews < ActiveRecord::Migration[8.1]
  def change
    add_column :pr_reviews, :enqueued_sha, :string
  end
end
