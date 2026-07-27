# frozen_string_literal: true

module Collavre
  module AiAgent
    # Renders the comments that Orchestration::TaskCoalescer folded into a task.
    #
    # When a burst of comments collapses into one turn, the superseded comments
    # survive only as ids in the payload's "merged_comment_ids". Every delivery
    # path that carries a trigger has to render them, because none of them can
    # fall back to chat history:
    #
    # - ClaudeChannelAdapter sends *only* comment.content to the MCP client.
    # - SessionContextResolver#incremental_payload sends *only* the :trigger
    #   message for session-backed agents.
    #
    # Blocks are chronological and labelled with their speaker, matching how
    # MessageBuilder labels chat history.
    class MergedTriggerComments
      Block = Struct.new(:comment, :text, :images, keyword_init: true)

      def self.for(context, agent:)
        new(context, agent: agent).blocks
      end

      # Prefix `content` with the merged comments, oldest first.
      def self.prepend_to(content, context, agent:)
        blocks = self.for(context, agent: agent)
        return content if blocks.empty?

        (blocks.map(&:text) + [ content.to_s ]).join("\n\n")
      end

      def initialize(context, agent:)
        @context = context || {}
        @agent = agent
      end

      # Ids of the coalesced comments, with the current anchor excluded — the
      # anchor is delivered as the trigger itself and must not be duplicated.
      def comment_ids
        @comment_ids ||= begin
          ids = Array(@context[Orchestration::TaskCoalescer::PAYLOAD_KEY])
                  .compact.map(&:to_i).uniq
          anchor_id = @context.dig("comment", "id")
          anchor_id ? ids - [ anchor_id.to_i ] : ids
        end
      end

      def blocks
        return [] if comment_ids.empty?

        # Memoized: MessageBuilder renders these into the trigger and also scans
        # them for creative references, and one build should not re-query.
        # Ordered by id, not created_at. A burst is exactly the case where the
        # rows are written by different processes, and created_at is stamped by
        # whichever one wrote it — clock skew or a tie can hand the agent
        # "ignore that" ahead of the instruction it retracts. Ids are the app's
        # single monotonic causal sequence (CommentsController orders by id for
        # the same reason).
        @blocks ||= Comment.public_only.without_approval_action
                           .where(id: comment_ids)
                           .includes(:user)
                           .order(:id)
                           .map { |c| Block.new(comment: c, text: label(c), images: image_blobs(c)) }
      end

      private

      def label(comment)
        text = comment.content.to_s
        if @agent && comment.user_id == @agent.id
          # Defensive: an agent's own message should never be coalesced into its
          # own trigger, but if one is, do not relabel it as a human speaker.
          "[#{@agent.name}]: #{text}"
        else
          text = MentionParser.strip_self_mention(text, @agent.name) if @agent
          "[#{comment.user&.name || 'unknown'}]: #{text}"
        end
      end

      def image_blobs(comment)
        comment.images.attached? ? comment.images.map(&:blob) : []
      end
    end
  end
end
