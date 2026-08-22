# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicMessageCreateServiceTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @reader = users(:two)
        @creative = Creative.create!(description: "Message Host", user: @owner)
        @topic = @creative.topics.create!(name: "Work", user: @owner)
        Current.user = @owner
      end

      teardown { Current.user = nil }

      test "posts a public message and returns its identity" do
        result = service.call(topic_id: @topic.id, content: "Start with the API contract.")
        comment = Comment.find(result[:id])

        assert_equal @topic.id, result[:topic_id]
        assert_equal @creative.id, result[:creative_id]
        assert_equal "Start with the API contract.", result[:content]
        assert_equal({ id: @owner.id, name: @owner.display_name }, result[:author])
        assert_equal @owner, comment.user
        assert_not comment.private?
      end

      test "uses normal comment dispatch exactly once for a human author" do
        events = []

        SystemEvents::Dispatcher.stub(:dispatch, ->(event, payload, **options) {
          events << [ event, payload, options ]
        }) do
          service.call(topic_id: @topic.id, content: "Human instruction")
        end

        assert_equal 1, events.size
        assert_equal "comment_created", events.first[0]
        assert_equal "comment_callback", events.first[2][:source]
      end

      test "an agent can create two pinned topics and start both with A2A instructions" do
        coordinator = create_agent("Coordinator", creator: @owner)
        worker = create_agent("Primary Worker", creator: @owner)
        share!(coordinator, :write)
        share!(worker, :feedback)
        Current.user = coordinator

        topics = %w[Research Delivery].map do |name|
          TopicCreateService.new.call(
            creative_id: @creative.id,
            name: name,
            primary_agent: worker.id.to_s
          )
        end
        events = []

        SystemEvents::Dispatcher.stub(:dispatch, ->(event, payload, **options) {
          events << [ event, payload, options ]
        }) do
          topics.each do |topic|
            service.call(topic_id: topic[:id], content: "Continue #{topic[:name]} independently.")
          end
        end

        assert_equal topics.pluck(:id), events.map { |event| event[1].dig(:topic, :id) }
        assert events.all? { |event| event[0] == "comment_created" && event[2][:source] == "a2a" }
        assert events.all? { |event| event[1][:workspace_user_id] == @owner.id }
        assert events.all? do |event|
          context = SystemEvents::ContextBuilder.new(event[1]).build
          Orchestration::Matcher.new(context).match == [ worker ]
        end
      end

      test "an agent can pin itself to two topics without creating a self-handoff loop" do
        coordinator = create_agent("Self Coordinator", creator: @owner)
        share!(coordinator, :write)
        Current.user = coordinator
        topics = %w[TrackOne TrackTwo].map do |name|
          TopicCreateService.new.call(
            creative_id: @creative.id,
            name: name,
            primary_agent: coordinator.id.to_s
          )
        end
        events = []

        SystemEvents::Dispatcher.stub(:dispatch, ->(_event, payload, **_options) { events << payload }) do
          topics.each do |topic|
            service.call(topic_id: topic[:id], content: "Continue #{topic[:name]} independently.")
          end
        end

        assert_equal topics.pluck(:id), events.map { |event| event.dig(:topic, :id) }
        assert events.all? { |event| event.dig(:sender, "id") == @owner.id }
        assert events.all? do |event|
          context = SystemEvents::ContextBuilder.new(event).build
          Orchestration::Matcher.new(context).match == [ coordinator ] && context.dig("sender", "is_ai") == false
        end
      end

      test "an agent without a human creator carries an explicitly empty workspace principal" do
        coordinator = create_agent("Unowned Coordinator", creator: nil)
        share!(coordinator, :feedback)
        Current.user = coordinator
        payload = nil

        SystemEvents::Dispatcher.stub(:dispatch, ->(_event, context, **_options) { payload = context }) do
          service.call(topic_id: @topic.id, content: "Agent instruction")
        end

        assert payload.key?(:workspace_user_id)
        assert_nil payload[:workspace_user_id]
      end

      test "feedback permission can post but read permission cannot" do
        share!(@reader, :feedback)
        Current.user = @reader

        assert service.call(topic_id: @topic.id, content: "Feedback")[:id]

        CreativeShare.find_by!(creative: @creative, user: @reader).update!(permission: :read)
        assert_raises(PermissionDeniedError) do
          service.call(topic_id: @topic.id, content: "Not allowed")
        end
      end

      test "reauthorizes after locking a topic moved to an inaccessible creative" do
        restricted = Creative.create!(description: "Restricted", user: @reader)
        lock_after_move = lambda do
          @topic.update_column(:creative_id, restricted.id)
          @topic.reload
        end

        Topic.stub(:find, @topic) do
          @topic.stub(:lock!, lock_after_move) do
            assert_raises(PermissionDeniedError) do
              service.call(topic_id: @topic.id, content: "Do not leak")
            end
          end
        end

        assert_not Comment.exists?(content: "Do not leak")
      end

      test "rejects blank content without creating a message" do
        assert_raises(ActiveRecord::RecordInvalid) do
          service.call(topic_id: @topic.id, content: "   ")
        end

        assert_not Comment.exists?(topic: @topic, content: "   ")
      end

      test "rejects archived topics and creatives" do
        @topic.archive!
        assert_raises(ArgumentError) { service.call(topic_id: @topic.id, content: "Closed") }

        @topic.unarchive!
        @creative.update!(archived_at: Time.current)
        assert_raises(ArgumentError) { service.call(topic_id: @topic.id, content: "Closed creative") }
      end

      test "rejects the inbox System topic" do
        inbox = Creative.create!(description: "Inbox", user: @owner, data: { "kind" => "inbox" })

        error = assert_raises(ArgumentError) do
          service.call(topic_id: inbox.system_topic.id, content: "Not a notification")
        end

        assert_includes error.message, "System topic"
      end

      test "requires a current user" do
        Current.user = nil

        assert_raises(RuntimeError) { service.call(topic_id: @topic.id, content: "No author") }
      end

      private

      def service
        TopicMessageCreateService.new
      end

      def create_agent(name, creator:)
        User.create!(
          name: name,
          email: "#{name.parameterize}-#{SecureRandom.hex(4)}@test.test",
          password: "password123",
          llm_vendor: "google",
          llm_model: "gemini-1.5-flash",
          searchable: true,
          creator: creator
        )
      end

      def share!(user, permission)
        CreativeShare.create!(creative: @creative, user: user, permission: permission, shared_by: @owner)
      end
    end
  end
end
