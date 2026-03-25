# frozen_string_literal: true

module Collavre
  module CommentSerializable
    extend ActiveSupport::Concern

    private

    def serialize_comments(comments)
      comments.map do |c|
        data = {
          "id" => c.id,
          "user_id" => c.user_id,
          "content" => c.content,
          "topic_id" => c.topic_id,
          "private" => c.private,
          "created_at" => c.created_at.iso8601,
          "quoted_comment_id" => c.quoted_comment_id,
          "quoted_text" => c.quoted_text,
          "review_type" => c.review_type
        }
        # Preserve attachment blob IDs for restore
        if c.images.attached?
          data["image_blob_ids"] = c.images.map { |img| img.blob_id }
        end
        data
      end
    end
  end
end
