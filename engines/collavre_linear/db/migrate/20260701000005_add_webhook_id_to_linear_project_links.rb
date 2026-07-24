class AddWebhookIdToLinearProjectLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :linear_project_links, :webhook_id, :string
  end
end
