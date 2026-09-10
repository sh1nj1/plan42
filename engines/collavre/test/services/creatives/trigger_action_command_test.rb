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
