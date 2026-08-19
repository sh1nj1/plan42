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
        :messages, :newest_message_id, :budget_exhausted,
        keyword_init: true
      ) do
        def returned_count = messages.size

        def returned_chars = messages.sum { |m| m[:content].to_s.length }

        def has_more? = (offset + returned_count) < total_count

        def next_offset = has_more? ? offset + returned_count : nil
      end

      def initialize(topic:, user:, offset: 0, limit: DEFAULT_LIMIT, order: DEFAULT_ORDER,
                     include_system: false, max_message_id: nil, char_budget: nil)
        @topic = topic
        @user = user
        @offset = [ offset.to_i, 0 ].max
        @limit = clamp_limit(limit)
        @order = ORDERS.include?(order.to_s) ? order.to_s : DEFAULT_ORDER
        @include_system = include_system
        @max_message_id = max_message_id
        @char_budget = char_budget
      end

      def call
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
          newest_message_id: @max_message_id || scope.maximum(:id),
          budget_exhausted: @char_budget && messages.size < @limit && (@offset + messages.size) < stat.count
        )
      end

      private

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
      # crosses the budget is kept whole rather than cut — a half message is
      # worse than one message too many, and stopping *before* it could return
      # zero rows and leave the caller paginating forever against an offset that
      # never advances.
      def within_budget(messages)
        return messages if @char_budget.nil?

        spent = 0
        kept = []
        messages.each do |message|
          break if spent >= @char_budget

          kept << message
          spent += message[:content].to_s.length
        end
        kept
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
