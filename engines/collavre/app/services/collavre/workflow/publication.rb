# frozen_string_literal: true

module Collavre
  module Workflow
    class Publication
      def initialize(row, token:)
        @row = row
        @token = token
        @execution = row.execution
      end

      def call
        return unless @row.owned(@token).where(state: "delivering").exists?
        error = reason
        return stop!(error) if error
        delivery = FallbackDelivery.new(@row, token: @token)
        SystemEvents::Dispatcher.dispatch_with_outcome(@execution.emits, @row.context, source: "workflow",
          selected_agents: delivery.pending_agents, ordinary_delivery: delivery, require_enqueue_ack: true)
      end

      private

      def stop!(error)
        @row.owned(@token).where(state: "delivering").update_all(
          state: "failed", reason: error, claim_token: nil, claimed_at: nil)
      end

      def reason
        safety = Safety.new(@execution)
        safety.reason || EnvelopeValidation.reason(@row.context) || identity_reason ||
          safety.comment_reason(Comment.find_by(id: @row.context.dig("comment", "id"))) || replies_reason
      end

      def identity_reason
        event = @row.context["event"]
        return "invalid_envelope" unless event["name"] == @execution.emits && event["source"] == "workflow"
        return "invalid_envelope" unless event["correlation_id"] == @execution.chain.correlation_id && event["causation_id"] == @execution.input_event_id
        return "scope_changed" unless @row.context.dig("creative", "id") == @execution.chain.creative_id && @row.context.dig("topic", "id").to_i == @execution.chain.topic_id
        @execution.chain.depth_reason(event["depth"])
      end

      def replies_reason
        @execution.admissions.each do |row|
          result = row.task&.workflow_result(previous_reply_id: row.reply_comment_id)
          return result || "task_failed" unless result == "completed"
        end
        nil
      end
    end
  end
end
