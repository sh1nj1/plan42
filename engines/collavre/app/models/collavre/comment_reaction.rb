module Collavre
  class CommentReaction < ApplicationRecord
    self.table_name = "comment_reactions"

    belongs_to :comment, class_name: "Collavre::Comment"
    belongs_to :user, class_name: Collavre.configuration.user_class_name

    validates :emoji, presence: true, length: { maximum: 16 }
    validates :user_id, uniqueness: { scope: [ :comment_id, :emoji ] }
  end
end
