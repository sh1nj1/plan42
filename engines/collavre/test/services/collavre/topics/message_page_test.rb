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

      def post_with_image(content: "", filename: "small.png")
        comment = Comment.new(
          creative: @creative, topic: @topic, user: @user, content: content,
          skip_default_user: true, skip_dispatch: true
        )
        comment.images.attach(
          io: StringIO.new(file_fixture("small.png").binread),
          filename: filename,
          content_type: "image/png"
        )
        comment.save!
        comment
      end

      # char_budget/format are spelled out here rather than in every caller,
      # since what the tests are exercising is the cap, not how it is packaged.
      def page(char_budget: nil, format: CharBudget::DEFAULT_FORMAT, **options)
        MessagePage.new(
          topic: @topic, user: @user,
          budget: CharBudget.new(chars: char_budget, format: format), **options
        ).call
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
        assert_nil result.next_cursor
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

      test "cursor does not skip remaining rows when an earlier row leaves the topic" do
        comments = 5.times.map { |i| post("m#{i}") }
        first = page(limit: 2, order: "desc")

        comments.last.update!(topic: @creative.topics.create!(name: "Moved", user: @user))
        second = page(
          limit: 2, order: "desc", offset: first.next_offset,
          max_message_id: first.newest_message_id, cursor: first.next_cursor
        )

        assert_equal %w[m4 m3], first.messages.map { |message| message[:content] }
        assert_equal %w[m2 m1], second.messages.map { |message| message[:content] }
      end

      test "cursor excludes an older message moved into the topic after the snapshot" do
        other_topic = @creative.topics.create!(name: "Other", user: @user)
        moved_in = Comment.create!(
          creative: @creative, topic: other_topic, user: @user, content: "moved in later",
          skip_default_user: true, skip_dispatch: true
        )
        3.times { |i| post("m#{i}") }
        first = page(limit: 1, order: "desc")

        CommentMoveService.new(creative: @creative, user: @user).call(
          comment_ids: [ moved_in.id ], target_topic_id: @topic.id
        )
        second = page(
          limit: 10, order: "desc", offset: first.next_offset,
          max_message_id: first.newest_message_id, cursor: first.next_cursor
        )

        assert_equal %w[m1 m0], second.messages.map { |message| message[:content] }
        assert_equal 3, second.total_count
        assert_not second.has_more?
      end

      test "cursor follows created_at and id ordering rather than id alone" do
        oldest = post("oldest")
        newest = post("newest")
        middle = post("middle")
        base = Time.current.change(usec: 0)
        oldest.update_column(:created_at, base)
        newest.update_column(:created_at, base + 2.seconds)
        middle.update_column(:created_at, base + 1.second)

        first = page(limit: 1, order: "desc")
        second = page(
          limit: 1, order: "desc", offset: first.next_offset,
          max_message_id: first.newest_message_id, cursor: first.next_cursor
        )

        assert_operator middle.id, :>, newest.id
        assert_equal "newest", first.messages.first[:content]
        assert_equal "middle", second.messages.first[:content]
      end

      test "content continuation keeps its cursor on the clipped row" do
        post("older")
        post("x" * 5_000)

        first = page(limit: 1, char_budget: 300, order: "desc")
        second = page(
          limit: 1, char_budget: 300, order: "desc",
          offset: first.next_offset, max_message_id: first.newest_message_id,
          cursor: first.next_cursor, content_offset: first.next_content_offset
        )

        assert_equal first.messages.first[:id], second.messages.first[:id]
        assert_equal first.next_cursor, second.next_cursor
      end

      test "content continuation resets when its cursor row leaves the topic" do
        older = post("older message")
        clipped = post("x" * 5_000)
        first = page(limit: 1, char_budget: 300, order: "desc")

        clipped.update!(topic: @creative.topics.create!(name: "Moved", user: @user))
        second = page(
          limit: 1, char_budget: 300, order: "desc",
          offset: first.next_offset, max_message_id: first.newest_message_id,
          cursor: first.next_cursor, content_offset: first.next_content_offset
        )

        assert_equal older.id, second.messages.first[:id]
        assert_equal "older message", second.messages.first[:content]
        assert_equal 0, second.messages.first.fetch(:content_offset, 0)
      end

      test "content continuation resets when its clipped row is edited" do
        clipped = post("x" * 5_000)
        first = page(limit: 1, char_budget: 300, order: "desc")

        clipped.update!(content: "replacement content")
        second = page(
          limit: 1, char_budget: 300, order: "desc",
          offset: first.next_offset, max_message_id: first.newest_message_id,
          cursor: first.next_cursor, content_offset: first.next_content_offset
        )

        assert_equal clipped.id, second.messages.first[:id]
        assert_equal "replacement content", second.messages.first[:content]
        assert_equal 0, second.messages.first.fetch(:content_offset, 0)
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

      test "an image-only comment exposes attachment metadata and a readable URL" do
        post_with_image

        content = page.messages.first[:content]
        assert_includes content, "Image attachment 1: small.png (image/png,"
        assert_match %r{/public-assets/blobs/[^/]+/small\.png}, content
      end

      test "an attached image is preserved alongside the message text" do
        post_with_image(content: "See the screenshot")

        content = page.messages.first[:content]
        assert_includes content, "See the screenshot"
        assert_includes content, "Image attachment 1: small.png"
      end

      test "attachment metadata follows content continuation without loss" do
        post_with_image(filename: "#{'screenshot-' * 18}.png")
        expected = page.messages.first[:content]
        chunks = []
        content_offset = 0

        20.times do
          result = page(limit: 1, char_budget: 260, content_offset: content_offset)
          chunks << result.messages.first[:content]
          content_offset = result.next_content_offset
          break unless content_offset

          assert_equal 0, result.next_offset
        end

        assert_nil content_offset
        assert_equal expected, chunks.join
      end

      test "reports a nil author as system" do
        Comment.create!(creative: @creative, topic: @topic, user: nil, content: "notice",
                        skip_default_user: true, skip_dispatch: true)

        assert_equal "system", page(include_system: true).messages.first[:author]
      end

      # The budget is a cap, so a message that would cross it ends the window
      # instead of being emitted on top of it.
      test "char_budget stops before a message that would cross it" do
        3.times { post("x" * 100) }
        budget = 150
        result = page(limit: 3, char_budget: budget)

        assert_equal 1, result.returned_count
        assert_operator result.billed_chars, :<=, budget
        assert result.budget_exhausted
      end

      # Stopping short of the *first* message would return an empty page at an
      # offset that has rows, and the caller would page against it forever. It
      # is clipped instead — bounded, marked, and addressable within the row.
      test "a message wider than the whole budget is clipped, not emitted whole" do
        post("y" * 5_000)
        budget = 400
        result = page(limit: 3, char_budget: budget)

        assert_equal 1, result.returned_count
        assert_operator result.billed_chars, :<=, budget
        assert result.messages.first[:clipped]
        assert_equal 0, result.messages.first[:content_offset]
        assert_equal 5_000, result.messages.first[:content_total_chars]
        assert_equal result.messages.first[:content_end_offset], result.next_content_offset
        assert_includes result.messages.first[:clip_notice], "continue with content_offset"
        assert_equal 1, result.clipped_count
      end

      test "a clipped message keeps its row offset and advances within its content" do
        post("y" * 5_000)
        post("z" * 5_000)
        result = page(limit: 3, char_budget: 400)

        assert_equal 0, result.next_offset
        assert_operator result.next_content_offset, :>, 0
        assert result.has_more?
      end

      test "content continuation retrieves every character before consuming the row" do
        content = ("0123456789" * 120).freeze
        post(content)
        chunks = []
        content_offset = 0
        anchor = nil

        20.times do
          result = page(
            limit: 1, char_budget: 260, order: "desc",
            content_offset: content_offset, max_message_id: anchor
          )
          anchor ||= result.newest_message_id
          chunks << result.messages.first[:content]
          content_offset = result.next_content_offset
          break unless content_offset

          assert_equal 0, result.next_offset
        end

        assert_nil content_offset
        assert_equal content, chunks.join
      end

      # No honest fragment exists below the envelope and the notice, so the page
      # comes back empty and says the budget, not the topic, is why.
      test "a budget too small for even the clip notice returns nothing" do
        post("y" * 5_000)
        result = page(limit: 3, char_budget: 10)

        assert_equal 0, result.returned_count
        assert result.budget_exhausted
        assert_equal 0, result.next_offset
        assert_equal 0, result.next_content_offset
      end

      test "clipped_count is zero when every message was emitted whole" do
        3.times { post("m") }

        assert_equal 0, page(limit: 3, char_budget: 10_000).clipped_count
      end

      # returned_chars is what the caller reads; billed_chars is what it pays.
      # Charging content alone lets a run of short messages emit ids, timestamps
      # and author names for free, and the response overruns max_chars.
      test "billed_chars charges the rendered envelope on top of the prose" do
        3.times { post("hi") }
        result = page(limit: 3)

        assert_equal 6, result.returned_chars
        assert_operator result.billed_chars, :>=, 6 + (3 * CharBudget::ENVELOPE_CHARS)
      end

      test "char_budget counts the envelope, so tiny messages still cost something" do
        5.times { post("x") }
        result = page(limit: 5, char_budget: 2 * CharBudget::ENVELOPE_CHARS)

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

      test "rejects a malformed cursor" do
        error = assert_raises(ArgumentError) { page(cursor: "not-a-cursor") }

        assert_equal "cursor is invalid", error.message
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
        assert_not result.has_more?
      end

      # nil is how the scope spells "unbounded", so an empty topic anchoring at
      # nil was not anchored at all: the snapshot the rest of the call reads is
      # whatever exists by the time each query runs, and the caller is handed no
      # anchor to pin the next page with. Zero is below every id, so it names
      # the empty snapshot instead of waiving the bound.
      test "an empty topic anchors at zero rather than leaving the snapshot unbounded" do
        assert_equal 0, page.newest_message_id
      end

      test "a message arriving mid-call cannot enter a snapshot that started empty" do
        stats = MessageStats.method(:for)
        MessageStats.stub(:for, ->(*args, **kwargs) { post("late"); stats.call(*args, **kwargs) }) do
          @result = page(limit: 10)
        end

        assert_equal 0, @result.total_count
        assert_empty @result.messages
        assert_equal 0, @result.newest_message_id
        assert_not @result.has_more?
      end
    end
  end
end
