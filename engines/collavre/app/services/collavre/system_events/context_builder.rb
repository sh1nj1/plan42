module Collavre
  module SystemEvents
    class ContextBuilder
      def initialize(context)
        @context = context
      end

      def build
        # Ensure context is a hash with string keys for Liquid
        ctx = @context.deep_stringify_keys

        # Add helper objects/functions
        if ctx["chat"]
          ctx["chat"]["mentioned_user"] ||= mentioned_user(ctx["chat"])
        end

        # Add sender context for A2A communication
        ctx["sender"] ||= build_sender_context(ctx)

        ctx
      end

      private

      def build_sender_context(ctx)
        user_id = ctx.dig("comment", "user_id")
        return nil unless user_id

        user = User.find_by(id: user_id)
        return nil unless user

        {
          "id" => user.id,
          "name" => user.name,
          "display_name" => user.respond_to?(:display_name) ? user.display_name : user.name,
          "is_ai" => user.ai_user?,
          "type" => user.ai_user? ? AgentTypeClassifier.classify(user) : "human"
        }
      end

      def mentioned_user(chat_context)
        content = chat_context["content"]
        return nil unless content

        user = MentionParser.resolve_user(content)
        user&.as_json(only: [ :id, :name, :email ])
      end
    end
  end
end
