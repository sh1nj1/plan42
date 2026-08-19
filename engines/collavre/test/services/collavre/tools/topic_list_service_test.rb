# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicListServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @stranger = users(:two)
        @creative = Collavre::Creative.create!(description: "List Host", user: @user)
        @main = @creative.main_topic(fallback_user: @user)
        @work = @creative.topics.create!(name: "Work", user: @user)
        Collavre::Current.user = @user
      end

      teardown { Collavre::Current.user = nil }

      def post(topic, content)
        Comment.create!(creative: @creative, topic: topic, user: @user, content: content,
                        skip_default_user: true, skip_dispatch: true)
      end

      def names(result) = result[:topics].map { |t| t[:name] }

      test "lists a creative's active topics with message totals" do
        post(@work, "hello")
        result = TopicListService.new.call(creative_id: @creative.id)

        work = result[:topics].find { |t| t[:name] == "Work" }
        assert_includes names(result), "Main"
        assert_equal 1, work[:message_count]
        assert_equal 5, work[:message_chars]
        assert_not_nil work[:last_message_at]
      end

      test "archived topics are hidden unless asked for" do
        @work.archive!

        assert_not_includes names(TopicListService.new.call(creative_id: @creative.id)), "Work"
        assert_includes names(TopicListService.new.call(creative_id: @creative.id, include_archived: true)), "Work"
      end

      test "include_stats false omits the totals" do
        post(@work, "hello")
        result = TopicListService.new.call(creative_id: @creative.id, include_stats: false)

        assert_not result[:topics].first.key?(:message_count)
      end

      test "a nil include_stats still counts, so an explicit null does not silently disable totals" do
        post(@work, "hello")
        result = TopicListService.new.call(creative_id: @creative.id, include_stats: nil)

        assert_equal 1, result[:topics].find { |t| t[:name] == "Work" }[:message_count]
      end

      test "include_system matches what topic_messages would return" do
        Comment.create!(creative: @creative, topic: @work, user: nil, content: "⏳",
                        skip_default_user: true, skip_dispatch: true)

        plain = TopicListService.new.call(creative_id: @creative.id)
        with_system = TopicListService.new.call(creative_id: @creative.id, include_system: true)

        assert_equal 0, plain[:topics].find { |t| t[:name] == "Work" }[:message_count]
        assert_equal 1, with_system[:topics].find { |t| t[:name] == "Work" }[:message_count]
      end

      test "topic_ids describes specific topics and reports the ones it cannot reach" do
        result = TopicListService.new.call(topic_ids: "#{@work.id},999999")

        assert_equal [ "Work" ], names(result)
        assert_equal [ { topic_id: 999_999, error: "Topic not found or not readable" } ], result[:errors]
      end

      test "topic_ids wins over creative_id when both are given" do
        result = TopicListService.new.call(creative_id: @creative.id, topic_ids: @work.id)

        assert_equal [ "Work" ], names(result)
      end

      test "reports a topic pinned to an agent" do
        agent = Collavre::User.create!(name: "Pinned", email: "pin-#{SecureRandom.hex(4)}@test.test",
                                       password: "password123", llm_vendor: "google")
        @work.set_primary_agent!(agent)

        work = TopicListService.new.call(topic_ids: @work.id)[:topics].first
        assert_equal "Pinned", work[:primary_agent][:name]
      end

      test "requires read permission on the creative" do
        Collavre::Current.user = @stranger

        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicListService.new.call(creative_id: @creative.id)
        end
      end

      test "a topic on an unreadable creative is an error entry, not a leak" do
        Collavre::Current.user = @stranger
        result = TopicListService.new.call(topic_ids: @work.id)

        assert_empty result[:topics]
        assert_equal "Topic not found or not readable", result[:errors].first[:error]
      end

      test "requires either creative_id or topic_ids" do
        assert_raises(ArgumentError) { TopicListService.new.call }
      end

      test "requires a current user" do
        Collavre::Current.user = nil

        assert_raises(RuntimeError) { TopicListService.new.call(creative_id: @creative.id) }
      end

      test "a linked creative lists the origin's topics" do
        link = Collavre::Creative.create!(description: "Link", user: @user, origin: @creative)

        assert_includes names(TopicListService.new.call(creative_id: link.id)), "Work"
      end
    end
  end
end
