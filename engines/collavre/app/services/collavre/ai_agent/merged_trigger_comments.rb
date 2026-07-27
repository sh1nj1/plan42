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

      TRUNCATION_SUFFIX = "…[truncated]"

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
        @blocks ||= within_budget(
          turn_scope(Comment.public_only.without_approval_action.where(id: comment_ids))
            .includes(:user)
            .order(:id)
            .map { |c| Block.new(comment: c, text: label(c), images: image_blobs(c)) }
        )
      end

      private

      # The merged ids were captured when the burst was folded; they are not a
      # standing claim on those rows. CommentMoveService#perform_move reassigns
      # creative_id, so a comment moved away while the task waited would still be
      # rendered into this trigger — handing the agent text and image attachments
      # from a creative it may have no share on. refresh_deferred_context! already
      # scopes its lookup this way; the merged set has to ask the same question.
      def turn_scope(relation)
        creative_id = @context.dig("creative", "id")
        relation = relation.where(creative_id: creative_id) if creative_id
        # topic_id nil is a real scope (a creative's Main topic), so key? rather
        # than presence decides whether the turn is topic-scoped at all.
        relation = relation.where(topic_id: @context.dig("topic", "id")) if @context.key?("topic")
        relation
      end

      # Coalescing turns a burst into one indivisible message, so an oversized
      # burst does not degrade — the whole turn fails. MessageBuilder budgets
      # chat history by the same setting; the trigger these blocks go into had
      # no budget at all, which is the asymmetry a burst is most likely to hit.
      #
      # Drop from the oldest end: the newest comments are the ones the anchor
      # replies to, and a retraction ("ignore that") is worthless without being
      # newer than what it retracts. Say what was cut — a silent truncation
      # reads to the agent as if the burst were complete.
      def within_budget(blocks)
        budget = size_limit
        return blocks if budget.nil? || blocks.sum { |b| b.text.length } <= budget

        # Dropping blocks rests on MessageBuilder leaving them in the separately
        # budgeted history window instead. A session-backed agent never receives
        # that window — SessionContextResolver#incremental_payload keeps only the
        # :trigger message — so for them a dropped block is a user comment with no
        # delivery path left, which is the loss coalescing exists to prevent.
        # Shrink every block instead, so an oversized burst degrades.
        return shrunk_to_fit(blocks, budget) if trigger_is_only_channel?

        # Reserve room for the omission marker. Added after budgeting, it pushed
        # the trigger back over the limit it had just been trimmed to.
        room = [ budget - omission_marker(blocks.size).length, 0 ].max

        kept = []
        used = 0
        blocks.reverse_each do |block|
          break if used + block.text.length > room

          used += block.text.length
          kept.unshift(block)
        end

        # The newest merged comment is the one the anchor replies to. When it
        # alone exceeds the budget the loop keeps nothing and the method returned
        # the marker by itself — the whole burst gone, newest included. Trim it
        # rather than drop it.
        kept = [ truncate_block(blocks.last, room) ] if kept.empty? && room.positive?

        dropped = blocks.size - kept.size
        return kept if dropped.zero?

        kept.unshift(Block.new(comment: nil, text: omission_marker(dropped), images: []))
      end

      # Fit every block, none dropped: each gets an equal share of the budget.
      # Used when the trigger is the only channel, where "which comments to keep"
      # is not a choice we are allowed to make.
      def shrunk_to_fit(blocks, budget)
        share = budget / blocks.size
        return [ truncate_block(blocks.last, budget) ] if share <= TRUNCATION_SUFFIX.length

        blocks.map { |b| truncate_block(b, share) }
      end

      def truncate_block(block, limit)
        return block if block.text.length <= limit

        text = if limit > TRUNCATION_SUFFIX.length
                 block.text[0, limit - TRUNCATION_SUFFIX.length] + TRUNCATION_SUFFIX
        else
                 block.text[0, limit]
        end
        Block.new(comment: block.comment, text: text, images: block.images)
      end

      def omission_marker(count)
        "[#{count} earlier message(s) omitted]"
      end

      # Does this agent receive anything other than the trigger?
      def trigger_is_only_channel?
        @agent.respond_to?(:supports_session?) && @agent.supports_session?
      end

      def size_limit
        @agent.respond_to?(:chat_history_size_limit) ? @agent.chat_history_size_limit : nil
      end

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
