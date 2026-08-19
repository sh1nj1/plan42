# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class MessagePageTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @other = users(:two)
        @creative = Collavre::Creative.create!(description: "Paging Host", user: @user)
        @topic = @creative.topics.create!(name: "Paged", user: @user)
      end

      def post(content, user: @user, private_flag: false, action: nil)
        Comment.create!(
          creative: @creative, topic: @topic, user: user, content: content,
          private: private_flag, action: action, skip_default_user: true, skip_dispatch: true
        )
      end

      def page(**options)
        MessagePage.new(topic: @topic, user: @user, **options).call
      end

      test "offset counts back from the newest message" do
        5.times { |i| post("m#{i}") }

        assert_equal %w[m4 m3 m2], page(limit: 3, order: "desc").messages.map { |m| m[:content] }
        assert_equal %w[m1 m0], page(offset: 3, limit: 3, order: "desc").messages.map { |m| m[:content] }
      end

      test "renders the window oldest-first by default while still selecting from the newest end" do
        5.times { |i| post("m#{i}") }

        assert_equal %w[m2 m3 m4], page(limit: 3).messages.map { |m| m[:content] }
      end

      test "reports totals for the whole topic, not the window" do
        4.times { |i| post("m#{i}") }
        result = page(limit: 2)

        assert_equal 4, result.total_count
        assert_equal 2, result.returned_count
        assert result.has_more?
        assert_equal 2, result.next_offset
      end

      test "has_more is false and next_offset nil once the window reaches the end" do
        2.times { |i| post("m#{i}") }
        result = page(limit: 10)

        assert_not result.has_more?
        assert_nil result.next_offset
      end

      test "excludes private comments the reader is not party to" do
        post("public one")
        post("secret", user: @other, private_flag: true)

        assert_equal [ "public one" ], page.messages.map { |m| m[:content] }
      end

      test "excludes authorless rows unless include_system" do
        post("real message")
        Comment.create!(creative: @creative, topic: @topic, user: nil, content: "⏳ waiting",
                        skip_default_user: true, skip_dispatch: true)

        assert_equal [ "real message" ], page.messages.map { |m| m[:content] }
        assert_equal 2, page(include_system: true).total_count
      end

      # Comment.without_approval_action is an invariant, not a preference: an
      # approval prompt must never reach an agent as history. include_system is
      # about authorless furniture and does not reopen that door.
      test "approval-action rows stay out even with include_system" do
        post("real message")
        post("approve me", action: '{"action":"approve_tool"}')

        result = page(include_system: true)
        assert_equal [ "real message" ], result.messages.map { |m| m[:content] }
        assert_equal 1, result.total_count
      end

      test "max_message_id pins the window so later arrivals do not shift it" do
        first_batch = 3.times.map { |i| post("m#{i}") }
        anchor = first_batch.last.id
        post("arrived later")

        result = page(limit: 2, max_message_id: anchor, order: "desc")
        assert_equal %w[m2 m1], result.messages.map { |m| m[:content] }
        assert_equal 3, result.total_count
        assert_equal anchor, result.newest_message_id
      end

      test "newest_message_id reports the topic's newest id when unpinned" do
        post("a")
        newest = post("b")

        assert_equal newest.id, page.newest_message_id
      end

      test "strips html from content and labels agent authors" do
        agent = Collavre::User.create!(name: "Bot", email: "bot-#{SecureRandom.hex(4)}@test.test",
                                       password: "password123", llm_vendor: "google")
        post("<p>hello <b>there</b></p>", user: agent)

        message = page.messages.first
        assert_equal "hello there", message[:content]
        assert message[:agent]
        assert_equal "Bot", message[:author]
      end

      test "reports a nil author as system" do
        Comment.create!(creative: @creative, topic: @topic, user: nil, content: "notice",
                        skip_default_user: true, skip_dispatch: true)

        assert_equal "system", page(include_system: true).messages.first[:author]
      end

      test "char_budget keeps the message that crosses the budget rather than cutting it" do
        3.times { post("x" * 100) }
        result = page(limit: 3, char_budget: 150)

        assert_equal 2, result.returned_count
        assert_equal 200, result.returned_chars
        assert result.budget_exhausted
      end

      # returned_chars is what the caller reads; billed_chars is what it pays.
      # Charging content alone lets a run of short messages emit ids, timestamps
      # and author names for free, and the response overruns max_chars.
      test "billed_chars charges the rendered envelope on top of the prose" do
        3.times { post("hi") }
        result = page(limit: 3)

        assert_equal 6, result.returned_chars
        assert_operator result.billed_chars, :>=, 6 + (3 * MessagePage::ENVELOPE_CHARS)
      end

      test "char_budget counts the envelope, so tiny messages still cost something" do
        5.times { post("x") }
        result = page(limit: 5, char_budget: 2 * MessagePage::ENVELOPE_CHARS)

        assert_operator result.returned_count, :<, 5
        assert result.budget_exhausted
      end

      test "budget_exhausted is false when the window simply ran out of messages" do
        2.times { |i| post("m#{i}") }

        assert_not page(limit: 10, char_budget: 10_000).budget_exhausted
      end

      test "limit is clamped to the maximum and falls back to the default when non-positive" do
        post("only")

        assert_equal MessagePage::MAX_LIMIT, page(limit: 10_000).limit
        assert_equal MessagePage::DEFAULT_LIMIT, page(limit: 0).limit
        assert_equal MessagePage::DEFAULT_LIMIT, page(limit: -5).limit
      end

      test "negative offset is treated as zero and unknown order falls back to the default" do
        2.times { |i| post("m#{i}") }
        result = page(offset: -3, order: "sideways")

        assert_equal 0, result.offset
        assert_equal %w[m0 m1], result.messages.map { |m| m[:content] }
      end

      # The anchor is what makes an unanchored first page safe to paginate from.
      # If it were read after the totals and the window, a message arriving
      # mid-call would be counted but not returned, and named as the newest
      # without ever having been in the window the caller was handed.
      test "a message arriving mid-call is outside the snapshot the page reports" do
        3.times { |i| post("m#{i}") }
        arrived = nil

        stats = MessageStats.method(:for)
        MessageStats.stub(:for, ->(*args, **kwargs) { arrived ||= post("late"); stats.call(*args, **kwargs) }) do
          @result = page(limit: 10)
        end

        assert_equal 3, @result.total_count
        assert_equal %w[m0 m1 m2], @result.messages.map { |m| m[:content] }
        assert_not_equal arrived.id, @result.newest_message_id
        assert_not @result.has_more?
      end

      test "an explicit anchor still wins over the topic's newest message" do
        3.times { |i| post("m#{i}") }
        anchor = Comment.order(:id).pluck(:id).second

        result = page(max_message_id: anchor, limit: 10)

        assert_equal 2, result.total_count
        assert_equal anchor, result.newest_message_id
      end

      test "an empty topic returns an empty page rather than failing" do
        result = page

        assert_equal 0, result.total_count
        assert_equal 0, result.total_chars
        assert_empty result.messages
        assert_nil result.newest_message_id
        assert_not result.has_more?
      end
    end
  end
end
