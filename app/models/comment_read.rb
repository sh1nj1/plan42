class CommentRead < ApplicationRecord
  belongs_to :comment
  belongs_to :user

  scope :unread, -> { where(read: false) }

  validates :comment_id, uniqueness: { scope: :user_id }
end
