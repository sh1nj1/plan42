# frozen_string_literal: true

module Collavre
  module Topics
    class TopicMove
      class SourceChangedError < StandardError; end
      MoveBlockedError = MoveBlocker::MoveBlockedError
      ActiveTaskError = MoveBlocker::ActiveTaskError
      RecurringTaskError = MoveBlocker::RecurringTaskError
      TriggerLoopError = MoveBlocker::TriggerLoopError

      def initialize(topic:, target_creative:)
        @topic = topic
        @target_creative = target_creative
        @source_creative_id = topic.creative_id
      end

      def call(after_commit: nil)
        result = Topic.transaction do
          # TopicBranchService locks the source before reading its comments.
          # Take the same parent-first lock order here so a branch cannot
          # authorize the old creative while this transaction has already
          # relocated the topic's comment rows to the new one.
          topic.lock!
          reject_changed_source!
          yield topic if block_given?
          MoveBlocker.new(topic).call
          topic.comments.update_all(creative_id: target_creative.id)
          topic.comment_snapshots.update_all(creative_id: target_creative.id)
          ReadPointerRelocator.new(topic: topic, target_creative: target_creative).call
          topic.update!(creative: target_creative)
          release_unroutable_primary_agent
        end
        schedule_after_commit(&after_commit) if after_commit
        result
      end

      private

      attr_reader :topic, :target_creative, :source_creative_id

      def reject_changed_source!
        return if topic.creative_id == source_creative_id

        raise SourceChangedError, I18n.t("collavre.topics.move.source_changed")
      end

      def schedule_after_commit(&callback)
        ActiveRecord.after_all_transactions_commit do
          current_topic = Topic.find(topic.id)
          current_topic.with_lock { callback.call(current_topic) }
        end
      end

      def release_unroutable_primary_agent
        agent = topic.primary_agent
        rejection = agent && Topic.primary_agent_rejection(target_creative, agent, topic: topic)
        return [ nil, nil ] unless rejection

        topic.set_primary_agent!(nil)
        [ agent, rejection ]
      end
    end
  end
end
