class CommentReadPointer < ApplicationRecord
  belongs_to :user
  belongs_to :creative
  belongs_to :last_read_comment, class_name: "Comment", optional: true

  validates :user_id, uniqueness: { scope: :creative_id }
end
