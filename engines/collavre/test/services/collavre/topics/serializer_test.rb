# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class SerializerTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = Collavre::Creative.create!(description: "Serialize Host", user: @user)
        @topic = @creative.topics.create!(name: "Work", user: @user)
        @agent = Collavre::User.create!(name: "Pinned", email: "pin-#{SecureRandom.hex(4)}@test.test",
                                        password: "password123", llm_vendor: "google")
      end

      test "the broadcast payload carries the pin, the lock flag and the unread count" do
        @topic.set_primary_agent!(@agent)
        data = Serializer.call(@topic, unread_count: 3)

        assert_equal @topic.id, data[:id]
        assert_equal "Pinned", data[:primary_agent][:name]
        assert_equal false, data[:agent_locked]
        assert_equal 3, data[:unread_count]
      end

      test "unread_count and archived_at are omitted when absent" do
        data = Serializer.call(@topic)

        assert_not data.key?(:unread_count)
        assert_not data.key?(:archived_at)
        assert_not data.key?(:primary_agent)
      end

      test "archived_at is included once the topic is archived" do
        @topic.archive!

        assert_not_nil Serializer.call(@topic)[:archived_at]
      end

      test "with_agent always carries primary_agent, explicitly nil when cleared" do
        data = Serializer.with_agent(@topic, nil)

        assert data.key?(:primary_agent)
        assert_nil data[:primary_agent]
      end

      test "the tool payload names the agent and flags main topics" do
        main = @creative.main_topic(fallback_user: @user)
        @topic.set_primary_agent!(@agent)

        assert Serializer.for_tool(main)[:main]
        assert_equal({ id: @agent.id, name: "Pinned" }, Serializer.for_tool(@topic)[:primary_agent])
      end

      test "the tool payload drops absent stats instead of reporting them as zero" do
        data = Serializer.for_tool(@topic)

        assert_not data.key?(:message_count)
        assert_equal false, data[:archived]
      end

      test "the tool payload reports stats when they are supplied" do
        data = Serializer.for_tool(@topic, message_count: 4, message_chars: 90, last_message_at: Time.current)

        assert_equal 4, data[:message_count]
        assert_equal 90, data[:message_chars]
        assert_match(/\A\d{4}-/, data[:last_message_at])
      end
    end
  end
end
