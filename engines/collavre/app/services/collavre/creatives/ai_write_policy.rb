# frozen_string_literal: true

module Collavre
  module Creatives
    class AiWritePolicy
      def self.review_required?(creatives)
        return false unless Current.agent_turn&.dig(:task) || Current.mcp_request

        Array(creatives).compact.uniq(&:id).any?(&:ai_write_review?)
      end

      def self.agent_anchor
        task = Current.agent_turn&.dig(:task)
        task&.topic_id ? Topic.find_by(id: task.topic_id)&.creative : nil
      end

      def self.capture(creatives:, anchor:, origin: :tool)
        return yield unless review_required?(creatives)

        effective_origin = Current.mcp_request ? :mcp : origin
        DraftChangeSetCapture.new(
          anchor: anchor || agent_anchor || Array(creatives).compact.first,
          origin: effective_origin
        ).call { yield }
      end
    end
  end
end
