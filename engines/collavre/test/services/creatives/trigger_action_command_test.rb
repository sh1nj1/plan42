# frozen_string_literal: true

require "test_helper"

module Collavre
  module Creatives
    class TriggerActionCommandTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @other_user = users(:two)
        @container = Creative.create!(
          user: @user,
          description: "Trigger Container",
          data: { "trigger" => { "on_child_enter" => true } }
        )
        @child = Creative.create!(user: @user, parent: @container, description: "Trigger Task")
        clear_enqueued_jobs
      end

      test "keep resume and restart require acknowledged dispatch" do
        { "resume" => "paused", "restart" => "completed" }.each do |action, state|
          @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @child.main_topic.id, source: "keep", state: state
          ) } })
          previous = @child.reload.data.deep_dup
          dispatch = lambda do |*args, **options|
            raise ActiveJob::EnqueueError if options[:require_enqueue_ack]
            [ users(:ai_bot) ]
          end
          SystemEvents::Dispatcher.stub(:dispatch, dispatch) do
            assert_raises(ActiveJob::EnqueueError) { command(action: action).call }
          end
          assert_equal previous, @child.reload.data
        end
      end

      test "keep controls roll back the entire transition when dispatch raises" do
        { "resume" => "paused", "restart" => "completed" }.each do |action, state|
          @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @child.main_topic.id, source: "keep", state: state, current_iteration: 3
          ) } })
          previous = @child.reload.data.deep_dup
          error = RuntimeError.new("dispatch failed")
          SystemEvents::Dispatcher.stub(:dispatch, ->(*) { raise error }) do
            assert_no_difference -> { @child.comments.count } do
              assert_same error, assert_raises(RuntimeError) { command(action: action).call }
            end
          end
          assert_equal previous, @child.reload.data
          SystemEvents::Dispatcher.stub(:dispatch, [ users(:ai_bot) ]) do
            assert_difference -> { @child.comments.count }, 1 do
              assert command(action: action).call.success?
            end
          end
        end
      end

      test "keep controls roll back when continuation creation fails" do
        { "resume" => "awaiting_user", "restart" => "max_reached" }.each do |action, state|
          @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @child.main_topic.id, source: "keep", state: state, current_iteration: 4
          ) } })
          previous = @child.reload.data.deep_dup
          operation = command(action: action)
          operation.stub(:create_trigger_comment, ->(*) { raise "creation failed" }) do
            assert_raises(RuntimeError) { operation.call }
          end
          assert_equal previous, @child.reload.data
        end
      end

      test "stale controls preserve a replacement keep in the same topic" do
        { "pause" => "running", "resume" => "paused", "restart" => "completed" }.each do |action, state|
          @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @child.main_topic.id, source: "keep", state: state, start_comment_id: 100
          ) } })
          operation = command(action: action)
          replacement = @child.data.deep_dup
          replacement["trigger"]["loop"]["start_comment_id"] = 200
          replacement["trigger"]["loop"]["generation"] += 1
          original = Comments::TopicMutation.method(:call)
          intercepted = false
          Comments::TopicMutation.stub(:call, lambda { |topic_id, creative_id, &block|
            unless intercepted
              intercepted = true
              Creative.where(id: @child.id).update_all(data: replacement)
            end
            original.call(topic_id, creative_id, &block)
          }) do
            SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Stale generation dispatched" }) do
              assert_no_difference -> { @child.comments.count } do
                assert operation.call.success?
              end
            end
          end
          assert_equal replacement, @child.reload.data
        end
      end

      test "stale controls do not lock or resume a replacement topic" do
        @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @child.main_topic.id, source: "keep", state: "paused"
        ) } })
        operation = command(action: "resume")
        replacement_topic = @child.topics.create!(name: "Replacement", user: @user)
        replacement = @child.data.deep_dup
        replacement["trigger"]["loop"]["trigger_topic_id"] = replacement_topic.id
        replacement["trigger"]["loop"]["generation"] += 1
        Creative.where(id: @child.id).update_all(data: replacement)
        locked_topics = []
        original = Comments::TopicMutation.method(:call)
        Comments::TopicMutation.stub(:call, lambda { |topic_id, creative_id, &block|
          locked_topics << topic_id
          original.call(topic_id, creative_id, &block)
        }) do
          SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Stale control dispatched" }) do
            operation.call
          end
        end
        assert_equal [ @child.main_topic.id ], locked_topics
        assert_equal replacement, @child.reload.data
      end

      test "keep resume and restart reject a missing selected agent" do
      { "resume" => "paused", "restart" => "completed" }.each do |action, state|
        @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @child.main_topic.id, source: "keep", agent_id: -1, state: state
        ) } })
        assert_no_difference -> { @child.comments.count } do
          refute command(action: action).call.success?
        end
        assert_equal state, @child.reload.data.dig("trigger", "loop", "state")
      end
    end

    test "drop resume keeps targeting the container agent" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @container, user: agent, permission: :write)
        topic = @child.topics.find_or_create_by!(name: "Drop Trigger") { |record| record.user = @user }
        @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(topic.id, state: "paused") } })
        previous_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        assert command(action: "resume").call.success?
        assert_match(/@#{Regexp.escape(agent.name)}:/, @child.comments.order(:id).last.content)
      ensure
        ActiveJob::Base.queue_adapter = previous_adapter
      end

      test "keep pause resume and restart reuse trigger actions with ambient routing" do
        SystemEvents::Dispatcher.stub(:dispatch, [ users(:ai_bot) ]) do
        topic = @child.main_topic
        @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          topic.id, source: "keep", goal: "Ship the feature"
        ) } })

        assert command(action: "pause").call.success?
        assert_equal "paused", @child.reload.data.dig("trigger", "loop", "state")
        assert_difference -> { @child.comments.count }, 1 do
          assert command(action: "resume").call.success?
        end
        refute_match(/@/, @child.comments.order(:id).last.content)

        data = @child.data.deep_dup
        data["trigger"]["loop"]["state"] = "completed"
        @child.update!(data: data)
        assert_difference -> { @child.comments.count }, 1 do
          assert command(action: "restart").call.success?
        end
        assert_includes @child.comments.order(:id).last.content, "Ship the feature"
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal "keep", @child.data.dig("trigger", "loop", "source")
        assert_equal topic.id, @child.comments.order(:id).last.topic_id
        assert_equal @container, @child.trigger_loop_context
        end
      end

      test "rejects unknown actions" do
        result = command(action: "invalid").call

        refute result.success?
        assert_equal :unprocessable_entity, result.status
        assert_equal I18n.t("collavre.drop_trigger.unknown_action"), result.error
      end

      test "rejects actions without write permission" do
        result = command(action: "pause", user: @other_user).call

        refute result.success?
        assert_equal :forbidden, result.status
        assert_equal I18n.t("collavre.creatives.errors.no_permission"), result.error
      end

      test "toggle_container updates the effective origin" do
        shell = Creative.create!(user: @other_user, origin: @container)
        command = command(creative: shell, action: "toggle_container", enabled: false)

        assert command.call.success?
        refute @container.reload.drop_trigger_enabled?
        assert_nil shell.reload.data&.dig("trigger", "on_child_enter")
      end

      test "toggle_container notifies only when enabling" do
        @container.update!(data: { "trigger" => { "on_child_enter" => false } })

        assert_difference -> { @container.comments.count }, 1 do
          assert command(action: "toggle_container", enabled: true, creative: @container).call.success?
        end
        assert_equal "Drop Trigger", @container.comments.order(:id).last.topic.name

        assert_no_difference -> { @container.comments.count } do
          assert command(action: "toggle_container", enabled: true, creative: @container).call.success?
        end
      end

      test "start enqueues the trigger job" do
        previous_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        begin
          assert_enqueued_with(job: DropTriggerJob, args: [ @container.id, @child.id ]) do
            assert command(action: "start").call.success?
          end
        ensure
          ActiveJob::Base.queue_adapter = previous_adapter
        end
      end

      test "start rejects a child outside a trigger container" do
        parent = Creative.create!(user: @user, description: "Normal Parent")
        child = Creative.create!(user: @user, parent: parent, description: "Normal Child")

        result = command(creative: child, action: "start").call

        refute result.success?
        assert_equal :unprocessable_entity, result.status
        assert_equal I18n.t("collavre.drop_trigger.not_a_container"), result.error
      end

      test "pause transitions running loop state" do
        set_loop_state("running", "current_iteration" => 2)

        assert command(action: "pause").call.success?
        assert_equal "paused", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 2, @child.data.dig("trigger", "loop", "current_iteration")
      end

      test "pause leaves an ineligible loop state unchanged" do
        set_loop_state("completed")

        assert command(action: "pause").call.success?
        assert_equal "completed", @child.reload.data.dig("trigger", "loop", "state")
      end

      test "resume transitions eligible state and posts continuation" do
        set_loop_state("awaiting_user", "current_iteration" => 3)
        command = command(action: "resume")
        posted = false
        command.define_singleton_method(:post_continue_to_agent) { posted = true }

        assert command.call.success?
        assert posted
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      end

      test "restart resets loop counters and posts a fresh trigger" do
        set_loop_state("max_reached", "current_iteration" => 8, "infra_retry_count" => 2)
        command = command(action: "restart")
        posted = false
        command.define_singleton_method(:post_restart_trigger) { posted = true }

        assert command.call.success?
        assert posted
        loop_data = @child.reload.data.dig("trigger", "loop")
        assert_equal "running", loop_data["state"]
        assert_equal 0, loop_data["current_iteration"]
        assert_equal 0, loop_data["infra_retry_count"]
      end

      test "stale linked toggle preserves the newly committed type and metadata" do
        shell = Creative.create!(user: @user, origin: @container)
        stale = shell.effective_origin
        latest = stale.data.merge("kind" => "project", "context_ids" => [ @child.id ])
        Creative.where(id: stale.id).update_all(data: latest)

        assert command(creative: shell, action: "toggle_container", enabled: false).call.success?
        assert_equal "project", @container.reload.creative_type
        assert_equal [ @child.id ], @container.data["context_ids"]
        refute @container.drop_trigger_enabled?
      end

      test "stale loop commands preserve newly committed type and counters" do
        { "pause" => "running", "resume" => "paused", "restart" => "completed" }.each do |action, state|
          set_loop_state(state)
          stale = Creative.find(@child.id)
          latest = @child.data.deep_merge("kind" => "project", "trigger" => { "loop" => { "max_iterations" => 42 } })
          Creative.where(id: @child.id).update_all(data: latest)
          operation = command(creative: stale, action: action)
          operation.define_singleton_method(:post_continue_to_agent) { }
          operation.define_singleton_method(:post_restart_trigger) { }

          assert operation.call.success?
          assert_equal "project", @child.reload.creative_type
          assert_equal 42, @child.data.dig("trigger", "loop", "max_iterations")
          assert_equal(action == "pause" ? "paused" : "running", @child.data.dig("trigger", "loop", "state"))
        end
      end

      test "keep controls preserve concurrently updated iteration settings" do
        @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @child.main_topic.id, source: "keep", current_comment_id: 999
        ) } })
        stale = Creative.find(@child.id)
        latest = @child.data.deep_merge("kind" => "project", "trigger" => { "loop" => { "max_iterations" => 42 } })
        Creative.where(id: @child.id).update_all(data: latest)
        assert command(creative: stale, action: "pause").call.success?
        assert_equal "paused", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 42, @child.data.dig("trigger", "loop", "max_iterations")
        assert_equal "project", @child.creative_type
      end

      test "stale pause cannot overwrite a newly completed loop" do
        set_loop_state("running")
        stale = Creative.find(@child.id)
        set_loop_state("completed")

        assert command(creative: stale, action: "pause").call.success?
        assert_equal "completed", @child.reload.data.dig("trigger", "loop", "state")
      end

      test "keep resume revalidates pause control version and agent before posting" do
        agent = users(:ai_bot)
        share = CreativeShare.create!(creative: @child, user: agent, permission: :feedback)
        %w[pause version permission].each do |change|
          @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @child.main_topic.id, source: "keep", state: "paused", agent_id: agent.id
          ) } })
          operation = command(action: "resume")
          original = operation.method(:post_continue_to_agent)
          operation.define_singleton_method(:post_continue_to_agent) do
            data = @creative.reload.data.deep_dup
            case change
            when "pause" then data["trigger"]["loop"]["state"] = "paused"
            when "version" then data["trigger"]["loop"]["control_version"] += 1
            when "permission"
              share.destroy!
              CreativeSharesCache.where(creative: @creative, user: agent).delete_all
            end
            @creative.update!(data: data)
            original.call
          end
          SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Stale resume must not dispatch" }) do
            assert_no_difference -> { @child.comments.count } do
              operation.call
            end
          end
          expected = change == "pause" ? "paused" : (change == "permission" ? "awaiting_user" : "running")
          assert_equal expected, @child.reload.data.dig("trigger", "loop", "state")
        end
      end

      test "keep resume dispatches once under the creative lock" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @child, user: agent, permission: :feedback)
        @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
          @child.main_topic.id, source: "keep", state: "paused", agent_id: agent.id
        ) } })
        depth = 0
        original_lock = @child.method(:with_lock)
        @child.define_singleton_method(:with_lock) do |*args, &block|
          original_lock.call(*args) do
            depth += 1
            begin
              block.call
            ensure
              depth -= 1
            end
          end
        end
        operation = command(action: "resume")
        created = nil
        original_create = operation.method(:create_trigger_comment)
        operation.define_singleton_method(:create_trigger_comment) do |*args, **kwargs|
          created = original_create.call(*args, **kwargs)
        end
        dispatches = []
        SystemEvents::Dispatcher.stub(:dispatch, lambda { |_event, payload, **_options|
          assert_operator depth, :>, 0
          dispatches << payload
          [ agent ]
        }) do
          operation.call
        end
        assert created.skip_dispatch
        assert_equal 1, dispatches.size
        assert_equal created.id, dispatches.first.dig(:comment, :id)
        assert_equal [ { id: agent.id } ], dispatches.first.dig(:chat, :mentioned_users)
      end

      private

      def command(creative: @child, user: @user, action:, enabled: nil)
        TriggerActionCommand.new(creative: creative, user: user, action: action, enabled: enabled)
      end

      def set_loop_state(state, attributes = {})
        @child.update!(data: { "trigger" => { "loop" => attributes.merge("state" => state) } })
      end
    end
  end
end
