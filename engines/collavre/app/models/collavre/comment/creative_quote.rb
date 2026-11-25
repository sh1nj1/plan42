module Collavre
  class Comment < ApplicationRecord
    # A message that quotes a passage of a creative (document mode selection)
    # rather than another chat message. "Review" asks the agent to revise the
    # quoted creative through a draft change set the user approves; "question"
    # asks about the passage and must never write.
    #
    # quoted_comment_id and quoted_creative_id are mutually exclusive — enforced
    # here and by the comments_single_quote_target check constraint.
    module CreativeQuote
      extend ActiveSupport::Concern

      included do
        belongs_to :quoted_creative, class_name: "Collavre::Creative", optional: true

        validate :single_quote_target

        # Messages that must run as their own agent turn and never be folded into,
        # absorb, or be dropped as context of another: a review is bound to the
        # comment it quotes, and a document-mode quote (review or question) is bound
        # to its creative — folding a question would also lose its read-only guard.
        scope :own_turn_messages, -> { review_messages.or(where.not(quoted_creative_id: nil)) }
      end

      class_methods do
        def own_turn_message_ids(ids)
          ids = Array(ids).compact.map(&:to_i).uniq
          return [] if ids.empty?

          own_turn_messages.where(id: ids).pluck(:id)
        end
      end

      def creative_quote?
        quoted_creative_id.present?
      end

      def creative_review_message?
        creative_quote? && !review_type_question?
      end

      def creative_question_message?
        creative_quote? && review_type_question?
      end

      private

      def single_quote_target
        return unless quoted_comment_id.present? && quoted_creative_id.present?

        errors.add(:base, I18n.t("collavre.comments.creative_quote.single_target"))
      end
    end
  end
end
