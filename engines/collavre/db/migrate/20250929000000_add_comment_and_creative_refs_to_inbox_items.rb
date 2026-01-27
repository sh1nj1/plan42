class AddCommentAndCreativeRefsToInboxItems < ActiveRecord::Migration[8.0]
  def change
    add_reference :inbox_items, :comment, foreign_key: { on_delete: :nullify }
    add_reference :inbox_items, :creative, foreign_key: { on_delete: :nullify }
  end
end
