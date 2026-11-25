# frozen_string_literal: true

module Collavre
  module Comments
    # The change set an agent proposed while answering a document-mode review
    # (Comment#creative_review_message?), as shown under the agent's reply: the
    # diff with approve/reject while it is a draft, then revert once applied —
    # all through the existing creative history endpoints.
    class CreativeQuoteReview
      attr_reader :change_set, :trigger

      def self.for_reply(comment)
        return unless comment.task_id && comment.user&.ai_user?

        quote_tasks = Task.where(id: comment.task_id,
                                 trigger_comment_id: Comment.where.not(quoted_creative_id: nil).select(:id))
        change_set = CreativeChangeSet.where(task_id: quote_tasks.select(:id)).order(id: :desc).first
        return unless change_set

        trigger = Comment.find_by(id: change_set.task.trigger_comment_id)
        new(comment, change_set, trigger) if trigger&.quoted_creative
      end

      def initialize(comment, change_set, trigger)
        @comment = comment
        @change_set = change_set
        @trigger = trigger
      end

      def quoted_creative = @trigger.quoted_creative

      # The creative the history endpoints are scoped through. The chat's own
      # creative normally contains every change; fall back to the quote target.
      def scope_creative
        @scope_creative ||= [ @comment.creative, quoted_creative ].compact.find do |creative|
          CreativeChangeSet.for_creative_scope(creative).exists?(id: @change_set.id)
        end
      end

      # Existing creatives the change touches outside the quoted subtree. A
      # created creative (negative virtual id) counts by its intended parent.
      def out_of_scope_ids
        allowed = quoted_creative.self_and_descendant_ids.to_set
        @change_set.creative_changes.filter_map do |change|
          id = change.creative_id.positive? ? change.creative_id : change.previous_parent_id
          # A child of another created creative is judged through that creative.
          next if id.nil? || id.negative? || allowed.include?(id)

          change.creative_id
        end.uniq
      end
    end
  end
end
