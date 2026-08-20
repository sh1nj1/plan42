# frozen_string_literal: true

module Collavre
  module Topics
    # One newest-first window of a topic's messages.
    #
    # Newest-first is the ordering the window is *selected* in: offset 0 is the
    # latest message. A conversation's recent end is the part worth reading when
    # you can only afford part of it, and it is the part whose position does not
    # change as the topic grows — an oldest-first offset would point somewhere
    # different every time a message arrived.
    class MessagePage
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200

      # Rendered oldest-first inside the window by default. The window is chosen
      # from the newest end; how it reads once chosen is a separate question,
      # and a summary written from a backwards transcript inverts cause and
      # effect. Callers wanting the raw newest-first order pass order: "desc".
      ORDERS = %w[asc desc].freeze
      DEFAULT_ORDER = "asc"

      Page = Struct.new(
        :topic, :total_count, :total_chars, :offset, :limit,
        :messages, :newest_message_id, :budget_exhausted, :budget,
        keyword_init: true
      ) do
        def returned_count = messages.size

        # What the caller reads.
        def returned_chars = messages.sum { |m| m[:content].to_s.length }

        # What the caller is charged: what emitting these messages in the
        # requested format costs, which is not what their prose measures.
        def billed_chars = messages.sum { |m| budget.cost(m) }

        # A clipped message is a partial answer that has_more cannot express:
        # the window did reach the end of the topic, it just could not print
        # all of the last thing it found.
        def clipped_count = messages.count { |m| m[:clipped] }

        def has_more? = (offset + returned_count) < total_count

        def next_offset = has_more? ? offset + returned_count : nil
      end

      # budget carries both the cap and the format it is counted in — see
      # CharBudget for why those cannot be separate arguments.
      def initialize(topic:, user:, offset: 0, limit: DEFAULT_LIMIT, order: DEFAULT_ORDER,
                     include_system: false, max_message_id: nil, budget: CharBudget.new)
        @topic = topic
        @user = user
        @offset = [ offset.to_i, 0 ].max
        @limit = clamp_limit(limit)
        @order = ORDERS.include?(order.to_s) ? order.to_s : DEFAULT_ORDER
        @include_system = include_system
        @max_message_id = max_message_id
        @budget = budget
      end

      def call
        anchor!
        stat = MessageStats.for(
          [ @topic ], user: @user, include_system: @include_system, max_message_id: @max_message_id
        ).fetch(@topic.id)
        messages = within_budget(fetch_window)

        Page.new(
          topic: @topic,
          total_count: stat.count,
          total_chars: stat.chars,
          offset: @offset,
          limit: @limit,
          messages: @order == "asc" ? messages.reverse : messages,
          newest_message_id: @max_message_id,
          budget_exhausted: !@budget.unlimited? && messages.size < @limit && (@offset + messages.size) < stat.count,
          budget: @budget
        )
      end

      private

      # An unanchored call picks its own anchor before it reads anything else,
      # so the totals, the window and the advertised newest_message_id all
      # describe one snapshot. Reading the anchor last instead lets a message
      # that arrives mid-call land in the totals but not the window, or be
      # named as newest without having been returned — and the caller then
      # pages with an anchor that shifts every offset under it, repeating one
      # message and skipping another.
      #
      # An empty topic anchors at 0 rather than nil, because nil is how this
      # scope spells "unbounded": leaving it there would let a message arriving
      # between the anchor and the totals query into both, and then advertise
      # no anchor for the caller to pin the next page with. Zero is below every
      # id, so it names the empty snapshot exactly, and Ruby's 0 is truthy —
      # a caller passing it back gets the same bound rather than a fresh anchor.
      def anchor!
        @max_message_id ||= MessageScope.for(
          @topic, user: @user, include_system: @include_system
        ).maximum(:id) || 0
      end

      def scope
        @scope ||= MessageScope.for(
          @topic, user: @user, include_system: @include_system, max_message_id: @max_message_id
        )
      end

      # id is the tiebreak, not decoration: comments posted inside the same
      # clock tick would otherwise order arbitrarily, and an unstable sort makes
      # offset pagination drop and repeat rows across pages.
      def fetch_window
        scope.includes(:user)
             .order(created_at: :desc, id: :desc)
             .offset(@offset)
             .limit(@limit)
             .map { |comment| serialize(comment) }
      end

      # Trims the newest-first window to the character budget. A message that
      # does not fit ends the window rather than being cut in half — except for
      # the first one, where stopping short would return zero rows at an offset
      # that does have rows and leave the caller paging against it forever.
      # That one is clipped to what the budget can pay for, with the clip
      # announced in its own text, so the cap holds and the offset still moves.
      def within_budget(messages)
        return messages if @budget.unlimited?

        spent = 0
        kept = []
        messages.each do |message|
          cost = @budget.cost(message)
          if @budget.fits?(cost, spent: spent)
            kept << message
            spent += cost
            next
          end

          clipped = kept.empty? ? clip(message) : nil
          kept << clipped if clipped
          break
        end
        kept
      end

      # Returns nil when the budget cannot pay even for the envelope and the
      # notice — there is no honest way to emit a fragment that small, and the
      # empty page carries budget_limited to say so.
      def clip(message)
        content = message[:content].to_s
        notice = clip_notice(content.length)
        room = widest_prefix(message, content, notice)
        return nil if room <= 0

        clipped(message, content, notice, room)
      end

      # The longest prefix of the prose whose rendered cost still fits.
      # Subtraction would do for markdown, where a character of content costs a
      # character of output, but json escapes the prose while serializing it, so
      # a slice can emit wider than it reads and arithmetic only gives an upper
      # bound. Cost rises monotonically with the prefix, so the exact answer is
      # a bisection — eighteen serializations at the largest cap, and only on
      # the clip path, which is one message per call at most.
      def widest_prefix(message, content, notice)
        low = 0
        high = content.length
        while low < high
          mid = (low + high + 1) / 2
          if @budget.fits?(@budget.cost(clipped(message, content, notice, mid)))
            low = mid
          else
            high = mid - 1
          end
        end
        low
      end

      def clipped(message, content, notice, take)
        message.merge(content: content[0, take] + notice, clipped: true)
      end

      # Counted against the budget like any other content, and phrased for the
      # reader of the transcript: the caller sees the clip where the words stop,
      # not only in a flag on the payload it may have rendered away.
      def clip_notice(total)
        "…[clipped from #{total} chars — raise max_chars for the rest]"
      end

      def serialize(comment)
        {
          id: comment.id,
          author: comment.user&.display_name || "system",
          author_id: comment.user_id,
          agent: comment.user&.ai_user? || false,
          created_at: comment.created_at&.iso8601,
          content: Collavre::HtmlText.plain(comment.content).strip
        }
      end

      def clamp_limit(limit)
        limit = limit.to_i
        return DEFAULT_LIMIT if limit <= 0

        [ limit, MAX_LIMIT ].min
      end
    end
  end
end
