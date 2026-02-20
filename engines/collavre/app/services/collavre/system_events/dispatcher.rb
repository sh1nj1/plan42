module Collavre
  module SystemEvents
    class Dispatcher
      def self.dispatch(event_name, context)
        new.dispatch(event_name, context)
      end

      def dispatch(event_name, context)
        comment_id = context.dig("comment", "id")
        comment_user_id = context.dig("comment", "user_id")
        creative_id = context.dig("creative", "id")
        Rails.logger.info(
          "[SystemEvents::Dispatcher] event=#{event_name} " \
          "comment_id=#{comment_id} comment_user_id=#{comment_user_id} " \
          "creative_id=#{creative_id} " \
          "caller=#{caller_locations(1, 5)&.map { |l| "#{File.basename(l.path)}:#{l.lineno}" }&.join(' <- ')}"
        )
        # Delegate to AgentOrchestrator for unified routing/scheduling
        Orchestration::AgentOrchestrator.dispatch(event_name, context)
      end
    end
  end
end
