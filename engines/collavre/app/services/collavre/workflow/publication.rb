# frozen_string_literal: true

module Collavre
  module Workflow
    class Publication
      def initialize(row)
        @row = row
        @execution = row.execution
      end

      def call
        error = reason
        return @row.finish!(error) if error
        SystemEvents::Dispatcher.dispatch_with_outcome(@execution.emits, @row.context, source: "workflow")
      end

      private

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
