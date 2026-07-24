class AddLastOutboundAtToLinearLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :linear_project_links, :last_outbound_at, :datetime
    add_column :linear_issue_links, :last_outbound_at, :datetime
  end
end
