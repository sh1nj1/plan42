module Collavre
  module SystemEvents
    class Dispatcher
      def self.dispatch(event_name, context)
        new.dispatch(event_name, context)
      end

      def dispatch(event_name, context)
        Rails.logger.info(
          "[SystemEvents::Dispatcher] event=#{event_name} " \
          "comment_id=#{context.dig('comment', 'id') || context.dig(:comment, :id)} " \
          "comment_user_id=#{context.dig('comment', 'user_id') || context.dig(:comment, :user_id)} " \
          "creative_id=#{context.dig('creative', 'id') || context.dig(:creative, :id)} " \
          "caller=#{caller_locations(1, 3)&.map { |l| "#{File.basename(l.path)}:#{l.lineno}" }&.join(' <- ')}"
        )
        # Delegate to AgentOrchestrator for unified routing/scheduling
        Orchestration::AgentOrchestrator.dispatch(event_name, context)
      end
    end
  end
end
