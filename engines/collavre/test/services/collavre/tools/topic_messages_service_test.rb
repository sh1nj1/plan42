# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicMessagesServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @stranger = users(:two)
        @creative = Collavre::Creative.create!(description: "Messages Host", user: @user)
        @a = @creative.topics.create!(name: "Alpha", user: @user)
        @b = @creative.topics.create!(name: "Beta", user: @user)
        Collavre::Current.user = @user
      end

      teardown { Collavre::Current.user = nil }

      def post(topic, content)
        Comment.create!(creative: @creative, topic: topic, user: @user, content: content,
                        skip_default_user: true, skip_dispatch: true)
      end

      def json(**args)
        TopicMessagesService.new.call(format: "json", **args)
      end

      def entry_for(payload, topic) = payload[:topics].find { |t| t[:topic_id] == topic.id }

      # The furniture every requested topic pays for whether or not it fits,
      # reserved up front so the not-fetched notices cannot themselves overrun
      # the cap that skipping produced them.
      def reserved_for(*topics)
        TopicMessagesService::TRUNCATION_CHARS +
          topics.sum { |t| TopicMessagesService::TOPIC_HEADER_CHARS.fetch("json") + t.name.length }
      end

      def billed_chars_of(topic) = entry_for(json(topic_ids: topic.id), topic)[:billed_chars]

      test "reads one topic newest-first and renders the window as a forward transcript" do
        3.times { |i| post(@a, "m#{i}") }
        payload = json(topic_ids: @a.id, limit: 2)

        assert_equal %w[m1 m2], entry_for(payload, @a)[:messages].map { |m| m[:content] }
        assert_equal 3, entry_for(payload, @a)[:total_count]
        assert_equal 2, entry_for(payload, @a)[:next_offset]
      end

      test "offset and limit apply per topic, and topics are never interleaved" do
        3.times { |i| post(@a, "a#{i}") }
        3.times { |i| post(@b, "b#{i}") }
        payload = json(topic_ids: "#{@a.id},#{@b.id}", limit: 2)

        assert_equal %w[a1 a2], entry_for(payload, @a)[:messages].map { |m| m[:content] }
        assert_equal %w[b1 b2], entry_for(payload, @b)[:messages].map { |m| m[:content] }
        assert_equal 2, entry_for(payload, @a)[:next_offset]
        assert_equal 2, entry_for(payload, @b)[:next_offset]
      end

      test "paging with the returned anchor stays on one snapshot while the topic grows" do
        4.times { |i| post(@a, "m#{i}") }
        first = json(topic_ids: @a.id, limit: 2)
        anchor = entry_for(first, @a)[:newest_message_id]

        post(@a, "arrived mid-read")
        second = json(topic_ids: @a.id, limit: 2, offset: 2, max_message_id: anchor)

        assert_equal %w[m0 m1], entry_for(second, @a)[:messages].map { |m| m[:content] }
        assert_not entry_for(second, @a)[:has_more]
      end

      test "order desc renders the window newest-first without changing which messages it selects" do
        3.times { |i| post(@a, "m#{i}") }
        payload = json(topic_ids: @a.id, limit: 2, order: "desc")

        assert_equal %w[m2 m1], entry_for(payload, @a)[:messages].map { |m| m[:content] }
      end

      test "max_chars is a whole-response cap, and a topic it cannot reach is reported unfetched" do
        post(@a, "x" * 500)
        post(@b, "y" * 500)
        # Sized from what Alpha actually bills rather than from a round number,
        # so this stays a test of the skip semantics and not of anyone's
        # arithmetic: room for both sections' furniture plus all of Alpha, and
        # nothing left for Beta.
        payload = json(topic_ids: "#{@a.id},#{@b.id}",
                       max_chars: reserved_for(@a, @b) + billed_chars_of(@a))

        assert payload[:truncated]
        assert_equal 1, entry_for(payload, @a)[:returned_count]
        assert_equal 0, entry_for(payload, @b)[:returned_count]
        assert_equal "max_chars budget spent on earlier topics", entry_for(payload, @b)[:skipped_reason]
        assert entry_for(payload, @b)[:has_more]
      end

      # "Nothing fit" and "the topics before you ate it" need different fixes,
      # so the first topic must not be told it lost a race it never ran.
      test "a first topic too large for the cap says so rather than blaming earlier topics" do
        post(@a, "x" * 500)
        payload = json(topic_ids: @a.id, max_chars: 50)

        assert_equal "max_chars is too small to return anything for this topic",
                     entry_for(payload, @a)[:skipped_reason]
      end

      test "budget_limited marks a topic the shared cap cut short" do
        3.times { post(@a, "x" * 1000) }
        payload = json(topic_ids: @a.id, max_chars: 2000)

        assert entry_for(payload, @a)[:budget_limited]
        assert payload[:truncated]
      end

      # max_chars is advertised as a cap on the response, so it has to bound
      # the response — headers and per-message envelopes included, not just the
      # prose. Hundreds of one-word messages used to cost almost nothing.
      test "the rendered response stays within max_chars when messages are tiny" do
        60.times { |i| post(@a, "m#{i}") }
        60.times { |i| post(@b, "n#{i}") }
        cap = 1_500
        markdown = TopicMessagesService.new.call(topic_ids: "#{@a.id},#{@b.id}", limit: 200, max_chars: cap)

        assert_operator markdown.length, :<=, cap
      end

      # The other way to blow the cap: one message bigger than the whole budget.
      # Envelope accounting alone did not stop it, because the loop appended
      # before it charged.
      test "the rendered response stays within max_chars against one oversized message" do
        post(@a, "y" * 50_000)
        cap = 1_200
        markdown = TopicMessagesService.new.call(topic_ids: @a.id, max_chars: cap)

        assert_operator markdown.length, :<=, cap
        assert_includes markdown, "clipped from 50000 chars"
      end

      # max_chars has to bound the response the caller actually receives, and
      # for format: "json" that is the serialized hash — every field name and
      # delimiter included. Charging markdown's 36-character envelope for a json
      # message undercounted it by roughly 120, so a few dozen short messages
      # sailed past the cap. Measured on to_json here for the same reason the
      # markdown tests measure the rendered string: the emitted form is the only
      # honest unit. (The MCP layer's own wrapper around this is out of scope —
      # this tool can only be accountable for what it returns.)
      test "the json response stays within max_chars when messages are tiny" do
        60.times { |i| post(@a, "m#{i}") }
        60.times { |i| post(@b, "n#{i}") }
        cap = 3_000

        payload = json(topic_ids: "#{@a.id},#{@b.id}", limit: 200, max_chars: cap)

        assert_operator payload.to_json.length, :<=, cap
        assert_operator entry_for(payload, @a)[:returned_count], :>, 0
      end

      # The other half of the undercount: json escapes the prose while it
      # serializes it, so a quote- and newline-heavy message emits far wider
      # than String#length reads. No fixed envelope constant can track that
      # ratio, which is why the cost is measured on the serialized form.
      test "the json response stays within max_chars when the prose is escape-heavy" do
        20.times { post(@a, %Q(He said "yes",\nthen "no",\tthen \\ nothing.\n) * 20) }
        cap = 6_000

        payload = json(topic_ids: @a.id, limit: 200, max_chars: cap)

        assert_operator payload.to_json.length, :<=, cap
        assert_operator entry_for(payload, @a)[:returned_count], :>, 0
      end

      # Clipping has to respect the format too. The raw subtraction that sized
      # the fragment is only an upper bound once escaping is in play, so the
      # clip is bisected against the serialized cost instead of assumed.
      test "the json response stays within max_chars against one oversized escape-heavy message" do
        post(@a, %Q("y"\n) * 12_500)
        cap = 1_500

        payload = json(topic_ids: @a.id, max_chars: cap)

        assert_operator payload.to_json.length, :<=, cap
        assert_equal 1, entry_for(payload, @a)[:clipped_count]
      end

      # json pays for its own structure, so the same cap buys strictly fewer
      # messages there. Pinning the direction guards against a later refactor
      # collapsing the two cost models back into one.
      test "json costs more of the budget than markdown for the same messages" do
        40.times { |i| post(@a, "m#{i}") }
        cap = 2_000

        as_json = json(topic_ids: @a.id, limit: 200, max_chars: cap)
        as_markdown = TopicMessagesService.new.call(topic_ids: @a.id, limit: 200, max_chars: cap)

        assert_operator entry_for(as_json, @a)[:returned_count], :<,
                        as_markdown.scan(/^\[\d+\] /).length
      end

      # has_more is false here — the window did reach the end of the topic — so
      # clipped_count is the only thing that can say the answer is partial.
      test "a clipped message marks the response truncated even with nothing left to page" do
        post(@a, "y" * 50_000)
        payload = json(topic_ids: @a.id, max_chars: 1_200)

        assert_equal 1, entry_for(payload, @a)[:clipped_count]
        assert payload[:truncated]
      end

      test "a fully returned topic is not marked truncated" do
        post(@a, "short")

        assert_not json(topic_ids: @a.id)[:truncated]
        assert_not entry_for(json(topic_ids: @a.id), @a).key?(:budget_limited)
        assert_not entry_for(json(topic_ids: @a.id), @a).key?(:clipped_count)
      end

      test "max_chars is clamped and defaults when non-positive" do
        post(@a, "hi")

        assert_equal TopicMessagesService::DEFAULT_MAX_CHARS, json(topic_ids: @a.id)[:max_chars]
        assert_equal TopicMessagesService::DEFAULT_MAX_CHARS, json(topic_ids: @a.id, max_chars: 0)[:max_chars]
        assert_equal TopicMessagesService::MAX_MAX_CHARS, json(topic_ids: @a.id, max_chars: 10_000_000)[:max_chars]
      end

      test "markdown is the default format and carries the same numbers as json" do
        2.times { |i| post(@a, "m#{i}") }
        output = TopicMessagesService.new.call(topic_ids: @a.id, limit: 1)

        assert_kind_of String, output
        assert_includes output, "## [topic #{@a.id}] Alpha"
        assert_includes output, "2 messages"
        assert_includes output, "offset: 1"
      end

      test "an unreadable or unknown topic is reported beside the ones that worked" do
        post(@a, "visible")
        payload = json(topic_ids: "#{@a.id},999999")

        assert_equal 1, entry_for(payload, @a)[:returned_count]
        assert_equal({ topic_id: 999_999, error: "Topic not found or not readable" },
                     payload[:topics].last)
      end

      test "a topic on a creative the caller cannot read is refused, not returned" do
        post(@a, "secret")
        Collavre::Current.user = @stranger
        payload = json(topic_ids: @a.id)

        assert_equal [ { topic_id: @a.id, error: "Topic not found or not readable" } ], payload[:topics]
      end

      test "more topics than the per-call cap are dropped from the tail, not silently merged" do
        ids = (1..TopicSelection::MAX_TOPICS + 2).map { |i| @creative.topics.create!(name: "T#{i}", user: @user).id }
        payload = json(topic_ids: ids.join(","))

        assert_equal TopicSelection::MAX_TOPICS, payload[:topics].size
      end

      test "requires at least one topic id" do
        assert_raises(ArgumentError) { json(topic_ids: "") }
        assert_raises(ArgumentError) { json(topic_ids: []) }
      end

      test "requires a current user" do
        Collavre::Current.user = nil

        assert_raises(RuntimeError) { json(topic_ids: @a.id) }
      end

      test "accepts an integer, a string and an array of ids alike" do
        post(@a, "hi")

        [ @a.id, @a.id.to_s, [ @a.id ], [ @a.id.to_s ] ].each do |ids|
          assert_equal 1, entry_for(json(topic_ids: ids), @a)[:returned_count]
        end
      end

      test "include_system pulls in authorless notices that are hidden by default" do
        Comment.create!(creative: @creative, topic: @a, user: nil, content: "⏳ waiting",
                        skip_default_user: true, skip_dispatch: true)

        assert_equal 0, entry_for(json(topic_ids: @a.id), @a)[:returned_count]
        assert_equal 1, entry_for(json(topic_ids: @a.id, include_system: true), @a)[:returned_count]
      end
    end
  end
end
