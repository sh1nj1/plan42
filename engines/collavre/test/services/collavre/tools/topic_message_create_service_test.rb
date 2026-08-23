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

        SystemEvents::Dispatcher.stub(:dispatch, ->(_event, payload, **options) {
          events << payload.deep_stringify_keys.deep_merge(options.fetch(:context_for).call(coordinator))
          [ coordinator ]
        }) do
          topics.each do |topic|
            service.call(topic_id: topic[:id], content: "Continue #{topic[:name]} independently.")
          end
        end

        assert_equal topics.pluck(:id), events.map { |event| event.dig("topic", "id") }
        assert events.all? { |event| event.dig("sender", "id") == @owner.id }
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

      test "marks a non-searchable agent tool message as AI-authored" do
        coordinator = create_agent("Private Coordinator", creator: @owner)
        coordinator.update!(searchable: false)
        share!(coordinator, :feedback)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: nil }
        payload = nil

        SystemEvents::Dispatcher.stub(:dispatch, ->(_event, context, **_options) {
          payload = context
          []
        }) do
          service.call(topic_id: @topic.id, content: "Private agent instruction")
        end

        assert_equal true, payload.dig(:comment, :from_ai)
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

      test "an agent uses its carried human when self-routed in a different unpinned topic" do
        coordinator = create_agent("Destination Coordinator", creator: @owner)
        coordinator.update!(routing_expression: "sender.is_ai == false")
        share!(coordinator, :feedback)
        destination = @creative.topics.create!(name: "Unpinned Destination", user: @owner)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }
        sender = nil
        dispatcher = lambda do |_event, _payload, **options|
          sender = options.fetch(:context_for).call(coordinator).fetch("sender")
          [ coordinator ]
        end

        result = SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
          service.call(topic_id: destination.id, content: "Route back from another topic")
        end

        assert_equal @owner.id, sender["id"]
        assert Comment.exists?(id: result[:id], topic: destination)
      end

      test "does not self-route when the delivered human sender fails the expression" do
        coordinator = create_agent("AI Sender Coordinator", creator: @owner)
        coordinator.update!(routing_expression: "sender.is_ai == true")
        share!(coordinator, :feedback)
        destination = @creative.topics.create!(name: "Humanized Destination", user: @owner)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }
        selected = nil
        dispatcher = lambda do |_event, _payload, **options|
          selected = options.fetch(:selection).agents
          []
        end

        SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
          service.call(topic_id: destination.id, content: "Only route for an AI sender")
        end

        assert_not_includes selected, coordinator
      end

      test "an agent without a principal cannot self-route in a different unpinned topic" do
        coordinator = create_agent("Principal-less Destination Coordinator", creator: @owner)
        coordinator.update!(routing_expression: "true")
        share!(coordinator, :feedback)
        destination = @creative.topics.create!(name: "Principal-less Destination", user: @owner)
        Current.user = coordinator
        Current.agent_turn = { user: nil, task: running_task(coordinator, @topic) }
        side_effects = []
        recorder = ->(*) { side_effects << true }
        error = CommentNotificationJob.stub(:perform_later, recorder) do
          CommentBadgesBroadcastJob.stub(:perform_later, recorder) do
            Turbo::Streams::BroadcastJob.stub(:perform_later, recorder) do
              Orchestration::AgentOrchestrator.stub(:prepare_selection, selection_for(coordinator)) do
                assert_raises(ArgumentError) do
                  service.call(topic_id: destination.id, content: "Unsafe self route")
                end
              end
            end
          end
        end

        assert_empty side_effects

        assert_equal I18n.t("collavre.tools.topic_message_create.errors.self_route"), error.message
        assert_not Comment.exists?(topic: destination, content: "Unsafe self route")
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
        dispatcher = ->(_event, _payload, **_options) { [ coordinator ] }

        Orchestration::LoopBreaker.stub(:new, ->(_context) { breaker }) do
          Orchestration::AgentOrchestrator.stub(:prepare_selection, selection_for(coordinator)) do
            SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
              service.call(topic_id: destination.id, content: "Start independent work")
            end
          end
        end

        assert_empty interactions
      end

      test "keeps a deliberate self-routed instruction eligible while deferred" do
        coordinator = create_agent("Deferred Coordinator", creator: @owner)
        blocker = create_agent("Deferred Blocker", creator: @owner)
        share!(coordinator, :feedback)
        share!(blocker, :feedback)
        destination = @creative.topics.create!(
          name: "Occupied Destination", user: @owner, primary_agent: coordinator
        )
        Task.create!(
          name: "Destination blocker", status: "running", trigger_event_name: "comment_created",
          trigger_event_payload: {}, agent: blocker, topic_id: destination.id, creative: @creative
        )
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }

        result = service.call(topic_id: destination.id, content: "Run after the blocker")
        waiter = Task.find_by!(status: "queued", agent: coordinator, topic_id: destination.id)

        Orchestration::AgentOrchestrator.send(:refresh_deferred_context!, waiter)

        assert_equal "queued", waiter.reload.status
        assert_equal result[:id], waiter.trigger_event_payload.dig("comment", "id")
        assert_equal @owner.id, waiter.trigger_event_payload.dig("sender", "id")
      end

      test "reselects the current primary after the comment commits" do
        coordinator = create_agent("Repin Coordinator", creator: @owner)
        former = create_agent("Former Primary", creator: @owner)
        current = create_agent("Current Primary", creator: @owner)
        share!(coordinator, :feedback)
        share!(former, :feedback)
        share!(current, :feedback)
        destination = @creative.topics.create!(
          name: "Repinned Destination", user: @owner, primary_agent: former
        )
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }
        selections = [ selection_for(former), selection_for(current) ]
        selected = nil
        prepare = lambda do |*_args, **_options|
          destination.update!(primary_agent: current) if selections.one?
          selections.shift
        end
        dispatcher = lambda do |_event, _payload, **options|
          selected = options.fetch(:selection).agents
          []
        end

        Orchestration::AgentOrchestrator.stub(:prepare_selection, prepare) do
          SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
            service.call(topic_id: destination.id, content: "Use the current primary")
          end
        end

        assert_equal [ current ], selected
      end

      test "does not advance round robin when a principal-less self-route is rejected" do
        coordinator = create_agent("Round Robin Coordinator", creator: @owner)
        worker = create_agent("Round Robin Worker", creator: @owner)
        share!(coordinator, :feedback)
        share!(worker, :feedback)
        destination = @creative.topics.create!(name: "Round Robin Destination", user: @owner)
        Current.user = coordinator
        Current.agent_turn = { user: nil, task: running_task(coordinator, @topic) }
        OrchestratorPolicy.create!(
          policy_type: "arbitration", config: { "strategy" => "round_robin" }
        )
        cache_key = "orchestrator:round_robin:topic:#{destination.id}"
        Rails.cache.delete(cache_key)
        matcher = Object.new
        matcher.define_singleton_method(:match) { [ coordinator, worker ] }

        Orchestration::Matcher.stub(:new, matcher) do
          assert_raises(ArgumentError) do
            service.call(topic_id: destination.id, content: "Rejected rotation")
          end
        end

        assert_nil Rails.cache.read(cache_key)
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
        Orchestration::LoopBreaker.stub(:new, ->(_context) { breaker }) do
          Orchestration::AgentOrchestrator.stub(:prepare_selection, selection_for(worker)) do
            dispatcher = lambda do |_event, _payload, **options|
              options.fetch(:on_scheduled).call([ worker ])
              [ worker ]
            end
            SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
              service.call(topic_id: @topic.id, content: "Track this handoff")
            end
          end
        end

        assert_equal [ [ coordinator.id, worker.id, @creative.id ] ], interactions
      end

      test "does not record interactions for scheduler-rejected agents" do
        coordinator = create_agent("Rejected Coordinator", creator: @owner)
        worker = create_agent("Rejected Worker", creator: @owner)
        share!(coordinator, :feedback)
        share!(worker, :feedback)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @creative.main_topic) }
        interactions = []
        breaker = Object.new
        breaker.define_singleton_method(:record_interaction) { |*args| interactions << args }
        dispatcher = lambda do |_event, _payload, **options|
          options.fetch(:on_scheduled).call([])
          []
        end

        Orchestration::LoopBreaker.stub(:new, ->(_context) { breaker }) do
          Orchestration::AgentOrchestrator.stub(:prepare_selection, selection_for(worker)) do
            SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
              service.call(topic_id: @topic.id, content: "Rejected handoff")
            end
          end
        end

        assert_empty interactions
      end

      test "scopes a carried human sender override to the selected coordinator" do
        coordinator = create_agent("Mixed Coordinator", creator: @owner)
        worker = create_agent("Mixed Worker", creator: @owner)
        share!(coordinator, :feedback)
        share!(worker, :feedback)
        Current.user = coordinator
        Current.agent_turn = { user: @owner, task: running_task(coordinator, @topic) }
        destination = @creative.topics.create!(name: "Mixed Destination", user: @owner)
        contexts = {}
        dispatcher = lambda do |_event, payload, **options|
          [ coordinator, worker ].each do |agent|
            contexts[agent.id] = payload.deep_stringify_keys.deep_merge(
              options.fetch(:context_for).call(agent)
            )
          end
          [ coordinator, worker ]
        end

        Orchestration::AgentOrchestrator.stub(
          :prepare_selection, selection_for(coordinator, worker)
        ) do
          SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
            service.call(topic_id: destination.id, content: "Coordinate and review")
          end
        end

        assert_equal @owner.id, contexts.dig(coordinator.id, "sender", "id")
        assert_equal false, contexts.dig(coordinator.id, "sender", "is_ai")
        assert_equal coordinator.id, contexts.dig(worker.id, "comment", "user_id")
        assert_nil contexts.dig(worker.id, "sender")
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

      def selection_for(*agents)
        Struct.new(:agents) { def commit! = self }.new(agents)
      end

      def share!(user, permission)
        CreativeShare.create!(creative: @creative, user: user, permission: permission, shared_by: @owner)
      end
    end
  end
end
