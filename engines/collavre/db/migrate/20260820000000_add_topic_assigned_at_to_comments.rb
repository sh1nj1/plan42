class AddTopicAssignedAtToComments < ActiveRecord::Migration[8.1]
  def up
    add_column :comments, :topic_assigned_at, :datetime, precision: 6
    execute "UPDATE comments SET topic_assigned_at = created_at"
    change_column_null :comments, :topic_assigned_at, false
    add_index :comments, %i[topic_id topic_assigned_at], name: "index_comments_on_topic_and_assigned_at"
  end

  def down
    remove_index :comments, name: "index_comments_on_topic_and_assigned_at"
    remove_column :comments, :topic_assigned_at
  end
end
