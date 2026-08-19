# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class MessageStatsTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = Collavre::Creative.create!(description: "Stats Host", user: @user)
        @a = @creative.topics.create!(name: "A", user: @user)
        @b = @creative.topics.create!(name: "B", user: @user)
      end

      def post(topic, content, user: @user)
        Comment.create!(creative: @creative, topic: topic, user: user, content: content,
                        skip_default_user: true, skip_dispatch: true)
      end

      test "counts, sizes and dates each topic separately in one pass" do
        post(@a, "1234567890")
        post(@a, "12345")
        post(@b, "abc")

        stats = MessageStats.for([ @a, @b ], user: @user)

        assert_equal 2, stats[@a.id].count
        assert_equal 15, stats[@a.id].chars
        assert_equal 1, stats[@b.id].count
        assert_equal 3, stats[@b.id].chars
        assert_not_nil stats[@a.id].last_at
      end

      test "a topic with no visible messages is reported as empty rather than missing" do
        stats = MessageStats.for([ @a ], user: @user)

        assert_equal MessageStats::EMPTY, stats[@a.id]
        assert_equal 0, stats[@a.id].count
        assert_nil stats[@a.id].last_at
      end

      test "returns nothing for an empty topic list" do
        assert_empty MessageStats.for([], user: @user)
      end

      test "system rows are counted only when asked for" do
        post(@a, "real")
        Comment.create!(creative: @creative, topic: @a, user: nil, content: "⏳",
                        skip_default_user: true, skip_dispatch: true)

        assert_equal 1, MessageStats.for([ @a ], user: @user)[@a.id].count
        assert_equal 2, MessageStats.for([ @a ], user: @user, include_system: true)[@a.id].count
      end

      test "max_message_id caps the totals at the snapshot" do
        anchor = post(@a, "first")
        post(@a, "later")

        assert_equal 1, MessageStats.for([ @a ], user: @user, max_message_id: anchor.id)[@a.id].count
      end
    end
  end
end
