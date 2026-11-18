# frozen_string_literal: true

module Collavre
  module Creatives
    class AiWritePolicy
      def self.review_required?(creatives, external_request: false, quote_turn: nil)
        return false unless external_request || Current.agent_turn&.dig(:task) || Current.mcp_request
        # A document-mode "review" request always goes through approval,
        # whatever the creative's own ai_write_policy says.
        quote_turn ||= CreativeQuoteTurn.current(external_request: external_request)
        return true if quote_turn&.review?

        Array(creatives).compact.uniq(&:id).any?(&:ai_write_review?)
      end

      def self.agent_anchor
        task = Current.agent_turn&.dig(:task)
        task&.topic_id ? Topic.find_by(id: task.topic_id)&.creative : nil
      end

      def self.capture(creatives:, anchor:, origin: :tool, external_request: false)
        quote_turn = CreativeQuoteTurn.current(external_request: external_request)
        return quote_turn.blocked_result if quote_turn&.write_blocked?

        effective_origin = Current.mcp_request || external_request ? :mcp : origin
        DraftChangeSetCapture.new(
          anchor: anchor || agent_anchor || Array(creatives).compact.first,
          origin: effective_origin,
          task: quote_turn&.task
        ).call(
          capture_required: review_required?(creatives, external_request: external_request, quote_turn: quote_turn)
        ) { yield }
      end
    end
  end
end
