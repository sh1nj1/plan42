module Collavre
  class CommentReaction < ApplicationRecord
    self.table_name = "comment_reactions"

    belongs_to :comment, class_name: "Collavre::Comment"
    belongs_to :user, class_name: Collavre.configuration.user_class_name

    validates :emoji, presence: true, length: { maximum: 16 }
    validates :user_id, uniqueness: { scope: [ :comment_id, :emoji ] }

    def self.broadcast_reaction_update(comment)
      creative = comment.creative
      reactions = comment.comment_reactions.reload.to_a
      payload = reactions.group_by(&:emoji).map do |emoji, grouped|
        { emoji: emoji, count: grouped.size, user_ids: grouped.map(&:user_id) }
      end

      Turbo::StreamsChannel.broadcast_action_to(
        [ creative, :comments ],
        action: "update_reactions",
        target: "comment_#{comment.id}",
        attributes: { data: payload.to_json }
      )
    end
  end
end
