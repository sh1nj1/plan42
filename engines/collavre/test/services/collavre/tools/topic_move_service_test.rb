# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicMoveServiceTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @member = users(:two)
        @source = Creative.create!(description: "Move source", user: @owner)
        @target = Creative.create!(description: "Move target", user: @owner)
        @topic = @source.topics.create!(name: "Relocate", user: @owner)
        Current.user = @owner
      end

      teardown { Current.user = nil }

      test "moves the topic, messages, snapshots, read cursors, and comment counters" do
        comment = Comment.create!(creative: @source, topic: @topic, user: @owner, content: "Keep together",
                                  skip_default_user: true, skip_dispatch: true)
        snapshot = CommentSnapshot.create!(
          creative: @source, topic: @topic, user: @owner, operation: "compress",
          comments_data: [ { "id" => comment.id, "topic_id" => @topic.id, "content" => comment.content } ]
        )
        pointer = CommentReadPointer.create!(
          user: @owner, creative: @source, topic: @topic, last_read_comment: comment
        )
        source_before = @source.reload.comments_count
        target_before = @target.reload.comments_count

        result = TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)

        assert_equal @target.id, @topic.reload.creative_id
        assert_equal @target.id, comment.reload.creative_id
        assert_equal @target.id, snapshot.reload.creative_id
        assert_equal @target.id, pointer.reload.creative_id
        assert_equal source_before - 1, @source.reload.comments_count
        assert_equal target_before + 1, @target.reload.comments_count
        assert_equal @target.id, result[:creative_id]
        assert_equal @source.id, result[:moved_from_creative_id]
        assert_nil result[:released_primary_agent]
      end

      test "broadcasts removal from the source and creation on the destination after moving" do
        broadcasts = []

        TopicsChannel.stub(:broadcast_to, ->(creative, payload) { broadcasts << [ creative.id, payload ] }) do
          TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)
        end

        assert_equal [ @source.id, @target.id ], broadcasts.map(&:first)
        assert_equal "deleted", broadcasts.first.last[:action]
        assert_equal @topic.id, broadcasts.first.last[:topic_id]
        assert_equal "created", broadcasts.second.last[:action]
        assert_equal @topic.id, broadcasts.second.last.dig(:topic, :id)
      end

      test "a linked destination resolves to its origin" do
        link = Creative.create!(description: "Target link", user: @owner, origin: @target)

        result = TopicMoveService.new.call(topic_id: @topic.id, creative_id: link.id)

        assert_equal @target.id, result[:creative_id]
        assert_equal @target.id, @topic.reload.creative_id
      end

      test "keeps a primary agent that can respond on the destination" do
        agent = create_agent("kept")
        share!(@source, agent, :feedback)
        share!(@target, agent, :feedback)
        @topic.set_primary_agent!(agent)

        result = TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)

        assert_equal agent.id, @topic.reload.primary_agent_id
        assert_equal agent.id, result.dig(:primary_agent, :id)
        assert_nil result[:released_primary_agent]
      end

      test "releases and explains a primary agent that cannot respond on the destination" do
        agent = create_agent("released")
        share!(@source, agent, :feedback)
        @topic.set_primary_agent!(agent)

        result = TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)

        assert_nil @topic.reload.primary_agent_id
        assert_equal agent.id, result.dig(:released_primary_agent, :id)
        assert_equal "no_creative_access", result.dig(:released_primary_agent, :reason)
        assert_includes result.dig(:released_primary_agent, :message), agent.display_name
      end

      test "explains session confinement when releasing a session agent in an inbox" do
        agent = create_agent("session")
        agent.update!(llm_vendor: "anthropic", llm_model: "claude-code")
        inbox = Creative.create!(description: "Inbox", user: @owner, data: { "kind" => "inbox" })
        share!(@source, agent, :feedback)
        share!(inbox, agent, :feedback)
        @topic.set_primary_agent!(agent)

        result = TopicMoveService.new.call(topic_id: @topic.id, creative_id: inbox.id)

        assert_nil @topic.reload.primary_agent_id
        assert_equal "session_agent_outside_session_topic", result.dig(:released_primary_agent, :reason)
        assert_equal I18n.t(
          "collavre.topics.move.primary_agent_released_session_agent",
          agent: agent.display_name, creative: inbox.creative_snippet
        ), result.dig(:released_primary_agent, :message)
      end

      test "requires admin permission on the source" do
        share!(@source, @member, :write)
        @target.update!(user: @member)
        Current.user = @member

        error = assert_raises(PermissionDeniedError) do
          TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)
        end

        assert_equal I18n.t("collavre.tools.topic_move.errors.source_permission"), error.message
        assert_equal @source.id, @topic.reload.creative_id
      end

      test "requires write permission on the destination" do
        @target.update!(user: @member)

        error = assert_raises(PermissionDeniedError) do
          TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)
        end

        assert_equal I18n.t("collavre.tools.topic_move.errors.target_permission"), error.message
        assert_equal @source.id, @topic.reload.creative_id
      end

      test "reauthorizes the source after acquiring the topic lock" do
        share!(@source, @member, :admin)
        share!(@target, @member, :write)
        Current.user = @member
        checks = 0
        authorize = lambda do |*_arguments, **_keywords|
          checks += 1
          next if checks == 1

          raise PermissionDeniedError, "revoked"
        end

        TopicAuthorizer.stub(:authorize_admin!, authorize) do
          assert_raises(PermissionDeniedError) do
            TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)
          end
        end

        assert_equal 2, checks
        assert_equal @source.id, @topic.reload.creative_id
      end

      test "rejects moving to the current creative" do
        assert_error(:same_creative, creative_id: @source.id)
      end

      test "rejects a duplicate topic name without moving messages" do
        comment = Comment.create!(creative: @source, topic: @topic, user: @owner, content: "Still here",
                                  skip_default_user: true, skip_dispatch: true)
        @target.topics.create!(name: @topic.name, user: @owner)

        assert_error(:duplicate_name, creative_id: @target.id, interpolation: { name: @topic.name })
        assert_equal @source.id, comment.reload.creative_id
      end

      test "rejects Main and an inbox destination's reserved System topic" do
        main = @source.main_topic
        main_error = assert_raises(ArgumentError) do
          TopicMoveService.new.call(topic_id: main.id, creative_id: @target.id)
        end

        ordinary_system = @source.topics.create!(name: Creative::SYSTEM_TOPIC_NAME, user: @owner)
        inbox = Creative.create!(description: "Inbox", user: @owner, data: { "kind" => "inbox" })
        system_error = assert_raises(ArgumentError) do
          TopicMoveService.new.call(topic_id: ordinary_system.id, creative_id: inbox.id)
        end

        expected = I18n.t("collavre.tools.topic_move.errors.reserved_topic")
        assert_equal expected, main_error.message
        assert_equal expected, system_error.message
        assert_equal @source.id, main.reload.creative_id
        assert_equal @source.id, ordinary_system.reload.creative_id
      end

      test "rejects a live agent session topic" do
        @topic.update!(session_id: "session-1")

        assert_error(:session_topic, creative_id: @target.id)
      end

      test "rejects a topic with active agent work" do
        Task.create!(name: "Moving work", agent: @owner, creative: @source, topic_id: @topic.id, status: :queued)

        error = assert_raises(Topics::TopicMove::ActiveTaskError) do
          TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)
        end

        assert_equal I18n.t("collavre.topics.move.active_tasks"), error.message
        assert_equal @source.id, @topic.reload.creative_id
      end

      test "rejects a stale move when the topic changes creatives before its lock" do
        intervening = Creative.create!(description: "Intervening", user: @owner)
        stale_move = Topics::TopicMove.new(topic: @topic, target_creative: @target)
        Topics::TopicMove.new(topic: @topic, target_creative: intervening).call

        assert_raises(Topics::TopicMove::SourceChangedError) { stale_move.call }
        assert_equal intervening.id, @topic.reload.creative_id
      end

      test "requires a current user" do
        Current.user = nil

        error = assert_raises(RuntimeError) do
          TopicMoveService.new.call(topic_id: @topic.id, creative_id: @target.id)
        end

        assert_equal I18n.t("collavre.tools.topic_move.errors.current_user_required"), error.message
      end

      test "every explicit tool error is translated in English and Korean" do
        keys = %i[
          current_user_required source_permission target_permission same_creative
          reserved_topic session_topic duplicate_name
        ]

        keys.each do |key|
          path = "collavre.tools.topic_move.errors.#{key}"
          assert I18n.exists?(path, :en), "missing en translation for #{path}"
          assert I18n.exists?(path, :ko), "missing ko translation for #{path}"
        end
      end

      private

      def create_agent(suffix)
        User.create!(
          name: "Move Agent #{suffix}", email: "move-agent-#{suffix}-#{SecureRandom.hex(3)}@test.test",
          password: "password123", llm_vendor: "openai", llm_model: "gpt-4", searchable: true
        )
      end

      def share!(creative, user, permission)
        CreativeShare.create!(creative: creative, user: user, permission: permission, shared_by: @owner)
      end

      def assert_error(key, creative_id:, interpolation: {})
        error = assert_raises(ArgumentError) do
          TopicMoveService.new.call(topic_id: @topic.id, creative_id: creative_id)
        end

        assert_equal I18n.t("collavre.tools.topic_move.errors.#{key}", **interpolation), error.message
        assert_equal @source.id, @topic.reload.creative_id
      end
    end
  end
end
