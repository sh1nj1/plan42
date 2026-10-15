# frozen_string_literal: true

module Collavre
  class Creative
    module TriggerLoop
      def keep_loop?
        data&.dig("trigger", "loop", "source") == "keep"
      end

      def trigger_loop_agent
        if keep_loop?
          agent = Collavre.user_class.find_by(id: data.dig("trigger", "loop", "agent_id"))
          return agent if agent&.ai_user? && Creatives::PermissionChecker.current_allowed?(id, agent, :feedback)
          return nil
        end

        parent&.find_ai_agent(:write)
      end

      def keep_loop_agent_unavailable?
        keep_loop? && data.dig("trigger", "loop", "agent_id").present? && trigger_loop_agent.nil?
      end

      def trigger_loop_task?(task)
        start_id = data&.dig("trigger", "loop", "start_comment_id")
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
