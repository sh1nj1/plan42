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
          ctx["chat"]["mentioned_users"] ||= default_mentioned_users(ctx["chat"])
          ctx["chat"]["mentioned_user"] ||= ctx["chat"]["mentioned_users"].first
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

      # The "chat" block for a comment the trigger has just been moved onto.
      #
      # Public for the same reason `sender_context_for` is: `build` only ever
      # fills "mentioned_user" in (`||=`) and does not run again on a
      # re-anchoring path, and AiAgentJob asks Matcher#assignment_permits?
      # against the raw payload. A mention left behind by the move therefore
      # reads as "no mention at all" — and an explicit mention is precisely what
      # outranks a topic's primary-agent assignment, so a restored or promoted
      # dispatch that *was* addressed to this agent gets refused for a topic
      # that belongs to someone else.
      #
      # The block is rebuilt rather than merged onto: a mention that finds
      # nobody must leave the keys absent, since Matcher reads their presence as
      # the mention that outranks the assignment.
      def self.reanchor_chat(content)
        chat = { "content" => content }
        mentions = mentioned_users_for(content)
        return chat if mentions.empty?

        chat.merge("mentioned_users" => mentions, "mentioned_user" => mentions.first)
      end

      # Every mentioned user, in mention order. Plural because a comment that
      # names two agents has to reach both: routing that keeps only the first
      # silently drops the rest, and "@someone: report / @agent: your turn" —
      # the shape the agent system prompt asks for — puts the human first.
      def self.mentioned_users_for(content)
        return [] unless content

        MentionParser.resolve_all_users(content).map { |user| user.as_json(only: [ :id, :name, :email ]) }
      end

      # The mentioned user ids carried by a payload, whatever shape it is in.
      #
      # The one reader for "who was mentioned", shared by Matcher and Arbiter:
      # they ask the same question on either side of a dispatch, and two private
      # copies of this lookup would drift the moment one of them learned about a
      # new key. Reads the plural key, falling back to the singular one so a task
      # queued before the plural key existed still routes to its agent.
      def self.mentioned_ids_in(context)
        chat = context["chat"] || context[:chat]
        return [] unless chat.is_a?(Hash)

        entries = chat["mentioned_users"] || chat[:mentioned_users]
        entries = [ chat["mentioned_user"] || chat[:mentioned_user] ] if entries.nil?

        Array(entries).filter_map do |entry|
          next unless entry.is_a?(Hash)

          id = entry["id"] || entry[:id]
          id&.to_i
        end
      end

      # Point a payload's sender at the comment the trigger has just been moved
      # onto. Only when the author actually changed: a payload may carry a sender
      # its producer shaped deliberately, and re-anchoring inside one user's own
      # burst is no reason to touch it.
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

      # A payload that already named its targets keeps them: its producer
      # resolved the mention against the roster it saw, and re-deriving from the
      # raw content would widen an in-flight single-target task into everyone
      # its text happens to name.
      def default_mentioned_users(chat_context)
        return [ chat_context["mentioned_user"] ] if chat_context["mentioned_user"]

        self.class.mentioned_users_for(chat_context["content"])
      end
    end
  end
end
