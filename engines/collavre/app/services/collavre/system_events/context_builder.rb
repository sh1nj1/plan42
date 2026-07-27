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

      # The sender block for a user, or nil when there is nobody to attribute to.
      #
      # Public because `build` only ever fills the key in (`||=`) and never runs
      # again on a promotion path: re-anchoring a coalesced task moves the trigger
      # to a different comment, so whoever moves it has to rebuild the sender from
      # the new author or the turn is labelled with the wrong speaker. Both callers
      # must produce the same shape — a stub missing "is_ai" silently flips the
      # A2A gate in AgentContextBuilder.
      def self.sender_context_for(user)
        return nil unless user

        {
          "id" => user.id,
          "name" => user.name,
          "display_name" => user.respond_to?(:display_name) ? user.display_name : user.name,
          "is_ai" => user.ai_user?,
          "type" => user.ai_user? ? AgentTypeClassifier.classify(user) : "human"
        }
      end

      # Point a payload's sender at the comment the trigger has just been moved
      # onto. Only when the author actually changed: a payload may carry a sender
      # its producer shaped deliberately (Comments::WorkflowExecutor attributes a
      # sub-task to the user who issued /work), and re-anchoring inside one user's
      # own burst is no reason to touch it.
      #
      # A rebuild that finds no user drops the key rather than leaving a wrong
      # one: ClaudeChannelAdapter then falls back to the comment's own user_id and
      # MessageBuilder omits the speaker label instead of naming the wrong person.
      def self.reanchor_sender(payload, comment)
        return payload unless payload.key?("sender")
        return payload if payload.dig("sender", "id") == comment.user_id

        sender = sender_context_for(comment.user)
        sender ? payload.merge("sender" => sender) : payload.except("sender")
      end

      private

      def build_sender_context(ctx)
        user_id = ctx.dig("comment", "user_id")
        return nil unless user_id

        self.class.sender_context_for(User.find_by(id: user_id))
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
