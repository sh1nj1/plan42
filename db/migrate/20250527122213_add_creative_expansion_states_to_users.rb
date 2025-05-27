class AddCreativeExpansionStatesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :creative_expansion_states, :jsonb
  end
end
