class BackfillCreativeInCommentInboxItems < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    InboxItem.where(message_key: [ "inbox.comment_added", "inbox.user_mentioned" ]).find_each do |item|
      params = item.message_params || {}
      next if params["creative"].present?

      comment_id = item.link.to_s[%r{/comments/(\d+)}, 1]
      next unless comment_id

      comment = Comment.find_by(id: comment_id)
      if comment.blank? || comment.creative.blank?
        params["creative"] = ""
      else
        snippet = comment.creative_snippet
        params["creative"] = snippet
      end

      item.update_columns(message_params: params)
    end
  end

  def down
    # no-op
  end
end
