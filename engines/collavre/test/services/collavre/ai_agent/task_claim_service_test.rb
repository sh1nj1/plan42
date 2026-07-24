# frozen_string_literal: true

require "test_helper"

module Collavre
  module AiAgent
    class TaskClaimServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:two)
        @creative = Creative.create!(user: @user, description: "Test")
        @topic = Topic.create!(creative: @creative, name: "test", user: @user)
        @service = TaskClaimService.new
      end

      def claimed_task
        # Exactly what #claim leaves behind: `done`, no comment linked yet.
        Task.create!(
          name: "Claimed dispatch",
          status: "done",
          agent: @agent,
          topic_id: @topic.id,
          creative_id: @creative.id
        )
      end

      def reason_for(task)
        @service.conflict_reason(agent: @agent, topic: @topic, requested_task_id: task.id)
      end

      # Codex P2: the winner's claim commits `done` a whole comment save before
      # #finalize links the reply, so the ordinary sibling race lands in that
      # window every time. Deciding on the first read made the loser's outcome —
      # silently deduped, or a hard error the model has to recover from — a
      # function of how fast the winner's INSERT was.
      test "a reply linked during the grace period is reported as dedup" do
        task = claimed_task
        comment = @creative.comments.create!(content: "The winner's answer", user: @agent, topic: @topic)

        reads = 0
        @service.define_singleton_method(:reply_linked?) do |t|
          reads += 1
          if reads == 1
            # #finalize lands in the winner's request just after this one looked.
            comment.update_column(:task_id, t.id)
            false
          else
            Comment.exists?(task_id: t.id)
          end
        end

        assert_equal TaskClaimService::CONFLICT_ALREADY_COMPLETED, reason_for(task)
        assert reads > 1, "must re-read rather than decide on the first look"
      end

      # The wait does not weaken the proof: a claim that never produces a reply
      # (the worker died mid-save) still surfaces, just after the deadline.
      test "a claim that never links a reply still surfaces, and is bounded" do
        task = claimed_task

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reason = reason_for(task)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_equal TaskClaimService::CONFLICT_CLAIMED_WITHOUT_REPLY, reason
        assert_operator elapsed, :>=, TaskClaimService::FINALIZE_GRACE_SECONDS,
          "must actually give finalization its window"
        assert_operator elapsed, :<, TaskClaimService::FINALIZE_GRACE_SECONDS * 4,
          "must not wait unbounded on a claim nobody will finish"
      end

      # An already-linked reply is the common dedup case and must not pay for
      # the grace period at all.
      test "an already-linked reply answers immediately" do
        task = claimed_task
        @creative.comments.create!(content: "Answered", user: @agent, topic: @topic)
                 .update_column(:task_id, task.id)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reason = reason_for(task)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_equal TaskClaimService::CONFLICT_ALREADY_COMPLETED, reason
        assert_operator elapsed, :<, TaskClaimService::FINALIZE_GRACE_SECONDS,
          "a task that was answered before the request arrived must not wait"
      end

      # A task that left `delegated` without ever being claimed has no
      # finalization to wait for — waiting would only delay the error.
      test "a non-done task answers immediately without waiting" do
        %w[cancelled failed pending delegated].each do |status|
          task = Task.create!(
            name: "Dispatch that went #{status}",
            status: status,
            agent: @agent,
            topic_id: @topic.id,
            creative_id: @creative.id
          )

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          reason = reason_for(task)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

          assert_equal TaskClaimService::CONFLICT_NOT_DELEGATED, reason, "#{status} must not be benign"
          assert_operator elapsed, :<, TaskClaimService::FINALIZE_GRACE_SECONDS,
            "#{status} has no claim in flight to wait for"
        end
      end
    end
  end
end
