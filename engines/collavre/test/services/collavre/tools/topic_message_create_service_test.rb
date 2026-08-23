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

      teardown { Current.reset }

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
          []
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
          [ worker ]
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
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }
        topics = %w[TrackOne TrackTwo].map do |name|
          TopicCreateService.new.call(
            creative_id: @creative.id,
            name: name,
            primary_agent: coordinator.id.to_s
          )
        end
        events = []

        SystemEvents::Dispatcher.stub(:dispatch, ->(_event, payload, **_options) {
          events << payload
          [ coordinator ]
        }) do
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

      test "an agent preserves an explicitly empty workspace principal" do
        coordinator = create_agent("Cleared Coordinator", creator: @owner)
        share!(coordinator, :feedback)
        Current.user = coordinator
        Current.agent_turn = { user: nil, task: nil }
        payload = nil

        SystemEvents::Dispatcher.stub(:dispatch, ->(_event, context, **_options) {
          payload = context
          []
        }) do
          service.call(topic_id: @topic.id, content: "Agent instruction")
        end

        assert payload.key?(:workspace_user_id)
        assert_nil payload[:workspace_user_id]
      end

      test "an agent preserves a carried human who is not its creator" do
        coordinator = create_agent("Carried Coordinator", creator: @owner)
        share!(coordinator, :feedback)
        Current.user = coordinator
        Current.agent_turn = { user: @reader, task: nil }
        payload = nil

        SystemEvents::Dispatcher.stub(:dispatch, ->(_event, context, **_options) {
          payload = context
          []
        }) do
          service.call(topic_id: @topic.id, content: "Carried instruction")
        end

        assert_equal @reader.id, payload[:workspace_user_id]
      end

      test "an agent preserves its parent event envelope" do
        coordinator = create_agent("Envelope Coordinator", creator: @owner)
        share!(coordinator, :feedback)
        Current.user = coordinator
        parent = SystemEvents::Envelope.root("comment_created", source: "test")
        task = running_task(coordinator, @topic, parent: parent)
        destination = @creative.topics.create!(name: "Envelope Destination", user: @owner)
        Current.agent_turn = { user: @reader, task: task }
        dispatch_options = nil

        SystemEvents::Dispatcher.stub(:dispatch, ->(_event, _context, **options) {
          dispatch_options = options
          []
        }) do
          service.call(topic_id: destination.id, content: "Child instruction")
        end

        assert_equal parent, dispatch_options[:parent]
      end

      test "an agent without a workspace principal cannot dispatch to itself" do
        coordinator = create_agent("Principal-less Coordinator", creator: @owner)
        share!(coordinator, :feedback)
        @topic.update!(primary_agent: coordinator)
        Current.user = coordinator
        Current.agent_turn = { user: nil, task: nil }

        error = assert_raises(ArgumentError) do
          service.call(topic_id: @topic.id, content: "Loop forever")
        end

        assert_match(/cannot dispatch a topic message to its own current topic/, error.message)
        assert_not Comment.exists?(topic: @topic, content: "Loop forever")
      end

      test "an agent cannot dispatch to its own currently running topic" do
        coordinator = create_agent("Busy Self Coordinator", creator: @owner)
        share!(coordinator, :feedback)
        @topic.update!(primary_agent: coordinator)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }

        error = assert_raises(ArgumentError) do
          service.call(topic_id: @topic.id, content: "Queue behind myself")
        end

        assert_match(/cannot dispatch a topic message to its own current topic/, error.message)
        assert_not Comment.exists?(topic: @topic, content: "Queue behind myself")
      end

      test "an agent cannot self-route in its unpinned current topic" do
        coordinator = create_agent("Expression Coordinator", creator: @owner)
        coordinator.update!(routing_expression: "true")
        share!(coordinator, :feedback)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }

        error = assert_raises(ArgumentError) do
          service.call(topic_id: @topic.id, content: "Route back to my expression")
        end

        assert_match(/cannot dispatch a topic message to its own current topic/, error.message)
        assert_not Comment.exists?(topic: @topic, content: "Route back to my expression")
      end

      test "an agent cannot self-route in a different unpinned topic" do
        coordinator = create_agent("Destination Coordinator", creator: @owner)
        coordinator.update!(routing_expression: "true")
        share!(coordinator, :feedback)
        destination = @creative.topics.create!(name: "Unpinned Destination", user: @owner)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }
        dispatcher = lambda do |_event, _payload, **options|
          options.fetch(:on_selected).call([ coordinator ])
        end

        error = SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
          assert_raises(ArgumentError) do
            service.call(topic_id: destination.id, content: "Route back from another topic")
          end
        end

        assert_equal I18n.t("collavre.tools.topic_message_create.errors.self_route"), error.message
        assert_not Comment.exists?(topic: destination, content: "Route back from another topic")
      end

      test "does not count self-pinned fan-out as a ping-pong interaction" do
        coordinator = create_agent("Fan-out Coordinator", creator: @owner)
        share!(coordinator, :feedback)
        destination = @creative.topics.create!(
          name: "Self Destination", user: @owner, primary_agent: coordinator
        )
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }
        interactions = []
        breaker = Object.new
        breaker.define_singleton_method(:record_interaction) { |*args| interactions << args }
        dispatcher = lambda do |_event, _payload, **options|
          options.fetch(:on_selected).call([ coordinator ])
          [ coordinator ]
        end

        Orchestration::LoopBreaker.stub(:new, ->(_context) { breaker }) do
          SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
            service.call(topic_id: destination.id, content: "Start independent work")
          end
        end

        assert_empty interactions
      end

      test "records tool-created A2A interactions for the selected agent" do
        coordinator = create_agent("Interaction Coordinator", creator: @owner)
        worker = create_agent("Interaction Worker", creator: @owner)
        unselected = create_agent("Unselected Worker", creator: @owner)
        share!(coordinator, :feedback)
        share!(worker, :feedback)
        share!(unselected, :feedback)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @creative.main_topic) }
        interactions = []
        breaker = Object.new
        breaker.define_singleton_method(:record_interaction) { |*args| interactions << args }
        matcher = Object.new
        matcher.define_singleton_method(:match) { [ worker, unselected ] }

        Orchestration::LoopBreaker.stub(:new, ->(_context) { breaker }) do
          Orchestration::Matcher.stub(:new, matcher) do
            dispatcher = lambda do |_event, _payload, **options|
              options.fetch(:on_selected).call([ worker ])
              [ worker ]
            end
            SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
              service.call(topic_id: @topic.id, content: "Track this handoff")
            end
          end
        end

        assert_equal [ [ coordinator.id, worker.id, @creative.id ] ], interactions
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
        error = assert_raises(ArgumentError) { service.call(topic_id: @topic.id, content: "Closed") }
        assert_equal I18n.t("collavre.tools.topic_message_create.errors.archived_topic"), error.message

        @topic.unarchive!
        @creative.update!(archived_at: Time.current)
        error = assert_raises(ArgumentError) do
          service.call(topic_id: @topic.id, content: "Closed creative")
        end
        assert_equal I18n.t("collavre.tools.topic_message_create.errors.archived_creative"), error.message
      end

      test "rejects the inbox System topic" do
        inbox = Creative.create!(description: "Inbox", user: @owner, data: { "kind" => "inbox" })

        error = assert_raises(ArgumentError) do
          service.call(topic_id: inbox.system_topic.id, content: "Not a notification")
        end

        assert_equal I18n.t("collavre.tools.topic_message_create.errors.system_topic"), error.message
      end

      test "requires a current user" do
        Current.user = nil

        error = assert_raises(RuntimeError) { service.call(topic_id: @topic.id, content: "No author") }
        assert_equal I18n.t("collavre.tools.topic_message_create.errors.current_user_required"), error.message
      end

      test "provides English and Korean translations for every tool error" do
        keys = %w[current_user_required archived_creative archived_topic system_topic current_topic self_route]

        keys.each do |key|
          path = "collavre.tools.topic_message_create.errors.#{key}"
          assert I18n.exists?(path, :en)
          assert I18n.exists?(path, :ko)
        end
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

      def running_task(agent, topic, parent: nil)
        payload = {
          "creative" => { "id" => topic.creative_id },
          "topic" => { "id" => topic.id }
        }
        payload[SystemEvents::Envelope::KEY] = parent.to_h if parent
        Task.create!(
          name: "Running topic message turn",
          status: "running",
          trigger_event_name: "comment_created",
          trigger_event_payload: payload,
          agent: agent,
          topic_id: topic.id,
          creative_id: topic.creative_id
        )
      end

      def share!(user, permission)
        CreativeShare.create!(creative: @creative, user: user, permission: permission, shared_by: @owner)
      end
    end
  end
end
