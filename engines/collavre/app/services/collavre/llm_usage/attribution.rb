# frozen_string_literal: true

module Collavre
  class LlmUsage
    # Accounting identity is independent of the workspace's authorization principal.
    class Attribution
      def self.from_payload(payload)
        ids = Array(payload["merged_comment_ids"]) + [ payload.dig("comment", "id") ]
        merge(payload.fetch("usage_requester_attribution", {}), from_comments(ids.compact))
      end

      def self.current_requesters
        task = Current.agent_turn&.dig(:task)
        return task.usage_attribution.slice("requester_ids", "source_comment_ids") if task

        user = Current.user
        { "requester_ids" => user && !user.ai_user? ? [ user.id ] : [], "source_comment_ids" => [] }
      end

      def self.from_comments(ids)
        requesters = []
        sources = ids.map(&:to_i)
        Comment.where(id: ids).includes(:user, :task).each do |comment|
          if comment.user && !comment.user.ai_user?
            requesters << comment.user_id
          elsif comment.task
            inherited = comment.task.usage_attribution
            requesters.concat(Array(inherited["requester_ids"]))
            sources.concat(Array(inherited["source_comment_ids"]))
          end
        end
        { "requester_ids" => requesters.uniq.sort, "source_comment_ids" => sources.uniq.sort }
      end

      def self.merge(original, additions)
        original.merge(
          "requester_ids" => (Array(original["requester_ids"]) + Array(additions["requester_ids"])).uniq.sort,
          "source_comment_ids" => (Array(original["source_comment_ids"]) + Array(additions["source_comment_ids"])).uniq.sort
        )
      end

      def self.snapshot(context)
        task = context[:task]
        return standalone(context) unless task

        task.with_lock do
          attribution = task.usage_attribution
          unless attribution.key?("owner_id")
            attribution = attribution.merge("owner_id" => task.agent.created_by_id)
            task.update!(usage_attribution: attribution)
          end
          attributes(attribution).merge(task_id: task.id, creative_id: task.creative_id, topic_id: task.topic_id)
        end
      end

      def self.standalone(context)
        comment = context[:comment]
        attribution = from_comments([ comment&.id ].compact).merge("owner_id" => context[:user]&.created_by_id)
        attributes(attribution).merge(creative_id: context[:creative]&.id, topic_id: comment&.topic_id)
      end

      def self.attributes(attribution)
        ids = Array(attribution["requester_ids"])
        {
          owner_id: attribution["owner_id"], requester_ids: ids,
          requester_id: ids.one? ? ids.first : nil,
          requester_kind: ids.empty? ? "unknown" : (ids.one? ? "human" : "joint"),
          source_comment_ids: Array(attribution["source_comment_ids"])
        }
      end
    end
  end
end
