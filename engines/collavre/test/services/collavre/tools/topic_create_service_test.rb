# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicCreateServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @stranger = users(:two)
        @creative = Collavre::Creative.create!(description: "Create Host", user: @user)
        @agent = Collavre::User.create!(name: "Worker", email: "worker-#{SecureRandom.hex(4)}@test.test",
                                        password: "password123", llm_vendor: "google",
                                        llm_model: "gemini-1.5-flash", searchable: true)
        Collavre::Current.user = @user
      end

      teardown { Collavre::Current.user = nil }

      def share!(permission)
        Collavre::CreativeShare.create!(creative: @creative, user: @agent, permission: permission,
                                        shared_by: @user)
      end

      test "creates a named topic on the creative" do
        result = TopicCreateService.new.call(creative_id: @creative.id, name: "Research")

        assert_equal "Research", result[:name]
        assert_equal @creative.id, result[:creative_id]
        assert @creative.topics.exists?(name: "Research")
      end

      test "falls back to the same generated name the UI would use" do
        result = TopicCreateService.new.call(creative_id: @creative.id)

        assert_equal Topics::NextName.for(@creative), "#{I18n.t('collavre.topics.default_name_prefix')}2"
        assert_equal "#{I18n.t('collavre.topics.default_name_prefix')}1", result[:name]
      end

      test "pins an agent that has feedback on the creative" do
        share!(:feedback)
        result = TopicCreateService.new.call(creative_id: @creative.id, name: "Pinned", primary_agent: "Worker")

        assert_equal({ id: @agent.id, name: "Worker" }, result[:primary_agent])
      end

      test "pins a private agent already shared on the creative" do
        @agent.update!(searchable: false)
        share!(:feedback)

        result = TopicCreateService.new.call(
          creative_id: @creative.id, name: "Shared Pin", primary_agent: "Worker"
        )

        assert_equal @agent.id, result.dig(:primary_agent, :id)
      end

      test "refuses to pin an agent with no access, and creates no topic" do
        error = assert_raises(ArgumentError) do
          TopicCreateService.new.call(creative_id: @creative.id, name: "Pinned", primary_agent: @agent.id.to_s)
        end

        assert_includes error.message, "no feedback permission"
        assert_not @creative.topics.exists?(name: "Pinned")
      end

      test "an unresolvable agent name is rejected before anything is created" do
        assert_raises(Topics::AgentResolver::UnknownAgentError) do
          TopicCreateService.new.call(creative_id: @creative.id, name: "Pinned", primary_agent: "Ghost")
        end

        assert_not @creative.topics.exists?(name: "Pinned")
      end

      test "moves existing messages into the new topic" do
        main = @creative.main_topic(fallback_user: @user)
        comment = Comment.create!(creative: @creative, topic: main, user: @user, content: "carry me",
                                  skip_default_user: true, skip_dispatch: true)

        result = TopicCreateService.new.call(creative_id: @creative.id, name: "Moved",
                                             comment_ids: comment.id.to_s)

        assert_equal result[:id], comment.reload.topic_id
      end

      test "a duplicate name is refused" do
        @creative.topics.create!(name: "Taken", user: @user)

        assert_raises(ActiveRecord::RecordInvalid) do
          TopicCreateService.new.call(creative_id: @creative.id, name: "Taken")
        end
      end

      test "an inbox topic cannot take the reserved System name" do
        inbox = Collavre::Creative.create!(description: "Inbox", user: @user, data: { "kind" => "inbox" })
        assert_nil inbox.topics.find_by(name: Collavre::Creative::SYSTEM_TOPIC_NAME)

        error = assert_raises(ArgumentError) do
          TopicCreateService.new.call(creative_id: inbox.id, name: Collavre::Creative::SYSTEM_TOPIC_NAME)
        end

        assert_includes error.message, "reserved"
        assert_nil inbox.topics.find_by(name: Collavre::Creative::SYSTEM_TOPIC_NAME)
      end

      test "System remains an ordinary topic name outside an inbox" do
        result = TopicCreateService.new.call(
          creative_id: @creative.id, name: Collavre::Creative::SYSTEM_TOPIC_NAME
        )

        assert_equal Collavre::Creative::SYSTEM_TOPIC_NAME, result[:name]
      end

      test "requires write permission on the creative" do
        Collavre::Current.user = @stranger

        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicCreateService.new.call(creative_id: @creative.id, name: "Nope")
        end
      end

      test "read permission alone is not enough" do
        Collavre::CreativeShare.create!(creative: @creative, user: @stranger, permission: :read, shared_by: @user)
        Collavre::Current.user = @stranger

        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicCreateService.new.call(creative_id: @creative.id, name: "Nope")
        end
      end

      test "requires a current user" do
        Collavre::Current.user = nil

        assert_raises(RuntimeError) { TopicCreateService.new.call(creative_id: @creative.id) }
      end

      test "a linked creative creates the topic on the origin" do
        link = Collavre::Creative.create!(description: "Link", user: @user, origin: @creative)
        result = TopicCreateService.new.call(creative_id: link.id, name: "Via link")

        assert_equal @creative.id, result[:creative_id]
      end

      test "announces the new topic so open clients see it, and selects it for the caller" do
        payload = nil
        Collavre::TopicsChannel.stub(:broadcast_to, ->(_creative, data) { payload = data }) do
          TopicCreateService.new.call(creative_id: @creative.id, name: "Announced")
        end

        assert_equal "created", payload[:action]
        assert_equal "Announced", payload[:topic][:name]
        assert_equal @user.id, payload[:user_id]
      end

      test "the announcement carries the pin so the sidebar shows the avatar immediately" do
        share!(:feedback)
        payload = nil
        Collavre::TopicsChannel.stub(:broadcast_to, ->(_creative, data) { payload = data }) do
          TopicCreateService.new.call(creative_id: @creative.id, name: "Announced", primary_agent: "Worker")
        end

        assert_equal @agent.id, payload[:topic][:primary_agent][:id]
      end
    end
  end
end
