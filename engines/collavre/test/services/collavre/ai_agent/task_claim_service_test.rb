# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class TaskClaimServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = Creative.create!(description: "Delegated timing", user: @user)
        @topic = @creative.topics.create!(name: "Replies", user: @user)
        @task = Task.create!(name: "Reply", creative: @creative, topic_id: @topic.id,
                             agent: @user, status: "delegated")
        @started_at = Time.current.change(usec: 0)
        @task.task_actions.create!(action_type: "start", status: "done", created_at: @started_at)
        @task.task_actions.create!(action_type: "delegated", status: "done", created_at: @started_at + 1)
        @claim_service = TaskClaimService.new
      end

      test "reply persists a measurable completion exactly once" do
        travel_to @started_at + 83 do
          result = reply

          assert_equal :created, result.status
          completion = @task.task_actions.find_by!(action_type: "completion")
          assert_equal Time.current, completion.created_at
          assert_equal "done", completion.status
          assert_equal result.comment.id, completion.payload["comment_id"]
          assert_equal 83, TaskExecutionTime.seconds(@task.reload)
          assert_equal @task.id, result.comment.reload.task_id
          assert_equal :conflict, reply.status
          assert_equal 1, @task.task_actions.where(action_type: "completion").count
        end
      end

      test "invalid reply leaves no completion and can be retried" do
        assert_equal :unprocessable_entity, reply(text: "").status
        assert_equal "delegated", @task.reload.status
        assert_not @task.task_actions.exists?(action_type: "completion")
        assert_nil @task.reply_comment
        assert_equal :created, reply.status
      end

      test "completion failure rolls back the claim and reply" do
        TaskAction.stub(:_insert_record, ->(*) { raise ActiveRecord::RecordNotSaved, "completion failed" }) do
          assert_no_difference "Comment.count" do
            assert_raises(ActiveRecord::RecordNotSaved) { reply }
          end
        end

        assert_equal "delegated", @task.reload.status
        assert_not @task.task_actions.exists?(action_type: "completion")
        assert_nil @task.reply_comment
      end

      test "finalizing a non-running task cannot record completion" do
        comment = @creative.comments.create!(user: @user, topic: @topic, content: "Reply")
        assert_raises(ActiveRecord::RecordNotSaved) do
          @claim_service.finalize(agent: @user, task: @task, comment: comment)
        end
        assert_not @task.task_actions.exists?(action_type: "completion")
      end

      private

      def reply(text: "Completed")
        TaskReplyService.new(
          topic: @topic, current_user: @user, text: text, requested_task_id: @task.id,
          agent_resolver: ->(*) { @user },
          task_claimer: ->(agent, topic, id) {
            @claim_service.claim(agent: agent, topic: topic, requested_task_id: id)
          },
          claim_service: @claim_service
        ).call
      end
    end
  end
end
