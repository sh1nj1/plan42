# frozen_string_literal: true

module Collavre
  class LlmUsage
    # Accounting identity is independent of the workspace's authorization principal.
    class Attribution
      def self.from_payload(payload)
        anchor = payload.dig("comment", "id")
        merged = Array(payload["merged_comment_ids"])
        if payload.key?("usage_requester_attribution")
          carried = merge(payload["usage_requester_attribution"], { "source_comment_ids" => [ anchor ].compact })
          merge(carried, from_comments(merged))
        else
          from_comments((merged + [ anchor ]).compact)
        end
      end

      def self.current_requesters
        task = Current.agent_turn&.dig(:task)
        return task.usage_attribution.slice("requester_ids", "source_comment_ids", "unknown_requester") if task

        user = Current.user
        { "requester_ids" => user && !user.ai_user? ? [ user.id ] : [], "source_comment_ids" => [] }
      end

      def self.from_comments(ids)
        comments = Comment.where(id: ids).includes(:user, :task).to_a
        initial = { "source_comment_ids" => ids.map(&:to_i).uniq.sort, "requester_ids" => [],
                    "unknown_requester" => comments.size < ids.uniq.size }
        comments.reduce(initial) { |result, comment| merge(result, from_comment(comment)) }
      end

      def self.from_comment(comment)
        return { "requester_ids" => [ comment.user_id ] } if comment.user && !comment.user.ai_user?

        inherited = comment.task&.usage_attribution || {}
        inherited.merge("unknown_requester" => inherited["unknown_requester"] || Array(inherited["requester_ids"]).empty?)
      end

      def self.merge(original, additions)
        original.merge(
          "unknown_requester" => original["unknown_requester"] || additions["unknown_requester"],
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
        sole_requester = ids.one? && !attribution["unknown_requester"]
        {
          owner_id: attribution["owner_id"], requester_ids: ids,
          requester_id: sole_requester ? ids.first : nil,
          requester_kind: ids.empty? ? "unknown" : (sole_requester ? "human" : "joint"),
          source_comment_ids: Array(attribution["source_comment_ids"])
        }
      end
    end
  end
end
