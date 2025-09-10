class BackfillCreativeInCommentInboxItems < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    InboxItem.where(message_key: [ "inbox.comment_added", "inbox.user_mentioned" ]).find_each do |item|
      params = item.message_params || {}
      next if params["creative"].present?

      comment_id = item.link.to_s[%r{/comments/(\d+)}, 1]
      next unless comment_id

      comment = Comment.find_by(id: comment_id)
      next unless comment

      snippet = comment.creative.effective_origin.description.to_plain_text.truncate(24, omission: "")
      params["creative"] = snippet
      item.update_columns(message_params: params)
    end
  end

  def down
    # no-op
  end
end
