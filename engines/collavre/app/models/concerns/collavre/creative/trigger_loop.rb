# frozen_string_literal: true

module Collavre
  class Creative
    module TriggerLoop
      def trigger_loop_control_target
        origin = effective_origin(Set.new)
        origin.keep_loop? ? origin : self
      end

      def trigger_loop_status
        trigger_loop_control_target.data&.dig("trigger", "loop")
      end

      def keep_loop?
        data&.dig("trigger", "loop", "source") == "keep"
      end

      def trigger_loop_agent
        if keep_loop?
          agent = Collavre.user_class.find_by(id: data.dig("trigger", "loop", "agent_id"))
          return agent if agent&.supports?(:chat) && Creatives::PermissionChecker.current_allowed?(id, agent, :feedback)
          return nil
        end

        parent&.find_ai_agent(:write, capability: :chat)
      end

      def keep_loop_agent_unavailable?
        keep_loop? && data.dig("trigger", "loop", "agent_id").present? && trigger_loop_agent.nil?
      end

      def trigger_loop_task?(task)
        loop_data = data&.dig("trigger", "loop") || {}
        return Collavre::KeepLoop.task?(self, task) if loop_data["source"] == "keep"

        if loop_data.key?("current_comment_id")
          ids = Collavre::KeepLoop.loop_comment_ids(task.trigger_event_payload || {})
          return loop_data["current_comment_id"].present? && ids.include?(loop_data["current_comment_id"])
        end

        start_id = loop_data["start_comment_id"]
        !start_id || task.trigger_event_payload&.dig("comment", "id").to_i >= start_id
      end

      def trigger_loop_enabled?
        keep_loop? || parent&.drop_trigger_enabled?
      end

      def trigger_loop_context
        return parent if parent&.drop_trigger_enabled?

        keep_loop? ? self : parent
      end
    end
  end
end
