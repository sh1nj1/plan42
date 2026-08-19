# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicUpdateServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @writer = users(:two)
        @creative = Collavre::Creative.create!(description: "Update Host", user: @user)
        @topic = @creative.topics.create!(name: "Work", user: @user)
        @agent = Collavre::User.create!(name: "Worker", email: "worker-#{SecureRandom.hex(4)}@test.test",
                                        password: "password123", llm_vendor: "google",
                                        llm_model: "gemini-1.5-flash", searchable: true)
        Collavre::Current.user = @user
      end

      teardown { Collavre::Current.user = nil }

      def share!(user, permission)
        Collavre::CreativeShare.create!(creative: @creative, user: user, permission: permission, shared_by: @user)
      end

      test "renames a topic and reports what changed" do
        result = TopicUpdateService.new.call(topic_id: @topic.id, name: "Renamed")

        assert_equal "Renamed", result[:name]
        assert_equal [ "name" ], result[:changed]
      end

      test "archives and unarchives" do
        assert_equal [ "archived" ], TopicUpdateService.new.call(topic_id: @topic.id, archived: true)[:changed]
        assert @topic.reload.archived?

        TopicUpdateService.new.call(topic_id: @topic.id, archived: false)
        assert_not @topic.reload.archived?
      end

      test "an archived topic keeps its messages and stays readable" do
        Comment.create!(creative: @creative, topic: @topic, user: @user, content: "kept",
                        skip_default_user: true, skip_dispatch: true)
        TopicUpdateService.new.call(topic_id: @topic.id, archived: true)

        payload = TopicMessagesService.new.call(topic_ids: @topic.id, format: "json")
        assert_equal 1, payload[:topics].first[:returned_count]
      end

      test "pins and clears the primary agent" do
        share!(@agent, :feedback)

        assert_equal [ "primary_agent" ],
                     TopicUpdateService.new.call(topic_id: @topic.id, primary_agent: "Worker")[:changed]
        assert_equal @agent.id, @topic.reload.primary_agent_id

        TopicUpdateService.new.call(topic_id: @topic.id, primary_agent: "none")
        assert_nil @topic.reload.primary_agent_id
      end

      test "several fields change in one call" do
        share!(@agent, :feedback)
        result = TopicUpdateService.new.call(topic_id: @topic.id, name: "Done", archived: true,
                                             primary_agent: "none")

        assert_equal %w[name archived primary_agent], result[:changed]
      end

      test "refuses to pin an agent without feedback on the creative" do
        error = assert_raises(ArgumentError) do
          TopicUpdateService.new.call(topic_id: @topic.id, primary_agent: @agent.id.to_s)
        end

        assert_includes error.message, "no feedback permission"
        assert_nil @topic.reload.primary_agent_id
      end

      test "a session topic's agent assignment is locked" do
        @topic.update!(session_id: "sess-1")
        share!(@agent, :feedback)

        error = assert_raises(ArgumentError) do
          TopicUpdateService.new.call(topic_id: @topic.id, primary_agent: "Worker")
        end

        assert_includes error.message, "session topic"
      end

      test "renaming needs admin, so a writer cannot rename" do
        share!(@writer, :write)
        Collavre::Current.user = @writer

        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicUpdateService.new.call(topic_id: @topic.id, name: "Nope")
        end
      end

      test "a writer can still archive and pin" do
        share!(@writer, :write)
        Collavre::Current.user = @writer

        assert_equal [ "archived" ], TopicUpdateService.new.call(topic_id: @topic.id, archived: true)[:changed]
      end

      test "a reader can do nothing" do
        share!(@writer, :read)
        Collavre::Current.user = @writer

        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicUpdateService.new.call(topic_id: @topic.id, archived: true)
        end
      end

      test "a call that changes nothing is an error rather than a silent no-op" do
        error = assert_raises(ArgumentError) { TopicUpdateService.new.call(topic_id: @topic.id) }

        assert_includes error.message, "Nothing to update"
      end

      test "requires a current user" do
        Collavre::Current.user = nil

        assert_raises(RuntimeError) { TopicUpdateService.new.call(topic_id: @topic.id, archived: true) }
      end

      test "broadcasts each change so open clients stay in step" do
        actions = []
        Collavre::TopicsChannel.stub(:broadcast_to, ->(_creative, data) { actions << data[:action] }) do
          TopicUpdateService.new.call(topic_id: @topic.id, name: "Renamed", archived: true)
        end

        assert_equal %w[updated archived], actions
      end

      test "clearing the pin broadcasts an explicit nil so the avatar is removed" do
        share!(@agent, :feedback)
        @topic.set_primary_agent!(@agent)

        payload = nil
        Collavre::TopicsChannel.stub(:broadcast_to, ->(_creative, data) { payload = data }) do
          TopicUpdateService.new.call(topic_id: @topic.id, primary_agent: "none")
        end

        assert payload[:topic].key?(:primary_agent)
        assert_nil payload[:topic][:primary_agent]
      end
    end
  end
end
