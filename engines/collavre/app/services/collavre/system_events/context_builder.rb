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

        ctx
      end

      private

      def mentioned_user(chat_context)
        # This mimics the chat.mentioned_user function requested
        # It assumes chat_context has 'content' or similar, or we might need to look up the comment
        # For now, let's assume the context passed in already has the necessary info or we extract it.
        # If the event is comment_created, the payload usually has the comment content.

        content = chat_context["content"]
        return nil unless content

        # Simple regex to find the first mention
        match = content.match(/\A@([^:]+?):\s*/) || content.match(/\A@(\S+)\s+/)
        return nil unless match

        name = match[1].strip
        user = User.where("LOWER(name) = ?", name.downcase).first
        user&.as_json(only: [ :id, :name, :email ])
      end
    end
  end
end
