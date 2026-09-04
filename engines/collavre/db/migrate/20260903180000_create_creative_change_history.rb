# frozen_string_literal: true

class CreateCreativeChangeHistory < ActiveRecord::Migration[8.0]
  def change
    add_column :creatives, :revision, :integer, null: false, default: 0

    create_table :creative_change_sets do |t|
      t.integer :anchor_creative_id
      t.string :anchor_source
      t.integer :user_id
      t.string :actor_kind, null: false
      t.string :origin, null: false
      t.integer :task_id
      t.integer :topic_id
      t.string :status, null: false, default: "applied"
      t.string :change_group_token
      t.text :summary
      t.integer :reverts_id
      t.integer :reverted_by_id
      t.datetime :applied_at
      t.timestamps

      t.index %i[anchor_creative_id created_at]
      t.index :status
      t.index :task_id
      t.index :reverts_id
      t.index %i[change_group_token user_id]
    end

    create_table :creative_changes do |t|
      t.references :creative_change_set, null: false, foreign_key: { on_delete: :cascade }
      t.integer :creative_id, null: false
      t.integer :previous_parent_id
      t.string :operation, null: false
      t.json :before, null: false, default: {}
      t.json :after, null: false, default: {}
      t.integer :position, null: false, default: 0
      t.json :conflict, null: false, default: {}
      t.timestamps

      t.index %i[creative_id id]
      t.index :previous_parent_id
      t.index %i[creative_change_set_id creative_id], unique: true,
                                                        name: "idx_creative_changes_on_set_and_creative"
    end
  end
end
