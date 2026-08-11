# frozen_string_literal: true

require "test_helper"

module Collavre
  module Onboarding
    class CompletionServiceTest < ActiveSupport::TestCase
      setup do
        @previous_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        clear_enqueued_jobs
      end

      teardown do
        ActiveJob::Base.queue_adapter = @previous_adapter
      end

      test "removes every item carrying the session id even after a practice item moves" do
        user = User.create!(name: "Finisher", email: "finisher@example.com", password: "password")
        session = Seeder.new(user: user).call
        moved = session.practice_creatives.first
        moved.update!(parent: nil)

        CompletionService.new(user: user).call

        assert_empty user.creatives.where(id: [ session.root.id, moved.id ])
        assert user.reload.onboarding_completed_at?
      end

      test "removes orphaned practice items after their onboarding root is deleted" do
        user = User.create!(name: "Deleted root finisher", email: "deleted-root-finisher@example.com", password: "password")
        session = Seeder.new(user: user).call
        practice_ids = session.practice_creatives.map(&:id)
        Creatives::DestroyService.new(creative: session.root, user: user).call

        CompletionService.new(user: user).call

        assert_empty user.creatives.where(id: practice_ids)
        assert user.reload.onboarding_completed_at?
      end

      test "defers cleanup while an onboarding comment has an active agent turn" do
        user = User.create!(name: "Awaiting finisher", email: "awaiting-finisher@example.com", password: "password")
        agent = User.create!(name: "Awaiting helper", email: "awaiting-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        comment = Comment.create!(creative: session.practice_creatives.second, user: user, content: "@Awaiting helper: Please help")
        task = Task.create!(name: "Response", status: "running", trigger_event_name: "comment_created",
                            trigger_event_payload: { "comment" => { "id" => comment.id } }, agent: agent,
                            creative: session.practice_creatives.second)

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id ]) do
          CompletionService.new(user: user).call(defer_pending_agent_cleanup: true)
        end

        assert Creative.exists?(session.root.id)
        assert user.reload.onboarding_completed_at?

        clear_enqueued_jobs
        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id, 1 ]) do
          OnboardingCleanupJob.perform_now(user.id, session.session_id)
        end
        assert Creative.exists?(session.root.id)

        task.update!(status: "done")
        OnboardingCleanupJob.perform_now(user.id, session.session_id)
        refute Creative.exists?(session.root.id)
      end

      test "defers cleanup while the onboarding agent job is queued before its task exists" do
        user = User.create!(name: "Queued finisher", email: "queued-finisher@example.com", password: "password")
        agent = User.create!(name: "Queued helper", email: "queued-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        comment = Comment.create!(creative: session.practice_creatives.second, user: user, content: "@Queued helper: Please help")
        ai_job = AiAgentJob.new(agent.id, "comment_created", { "comment" => { "id" => comment.id } })
        SolidQueue::Job.create!(class_name: AiAgentJob.name, queue_name: "ai_agents", arguments: ai_job.serialize)

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id ]) do
          CompletionService.new(user: user).call(defer_pending_agent_cleanup: true)
        end

        assert Creative.exists?(session.root.id)
      end

      test "removes a deferred session after its agent turn settles" do
        user = User.create!(name: "Settled finisher", email: "settled-finisher@example.com", password: "password")
        session = Seeder.new(user: user).call

        OnboardingCleanupJob.perform_now(user.id, session.session_id)
        refute Creative.exists?(session.root.id)
      end

      test "cleans up after an onboarding agent turn settles beyond the retry window" do
        user = User.create!(name: "Pending approval finisher", email: "pending-approval-finisher@example.com", password: "password")
        agent = User.create!(name: "Pending approval helper", email: "pending-approval-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        comment = Comment.create!(creative: session.practice_creatives.second, user: user, content: "@Pending approval helper: Please help")
        task = Task.create!(name: "Awaiting approval", status: "pending_approval", trigger_event_name: "comment_created",
                            trigger_event_payload: { "comment" => { "id" => comment.id } }, agent: agent,
                            creative: session.practice_creatives.second)

        CompletionService.new(user: user).call(defer_pending_agent_cleanup: true)
        clear_enqueued_jobs

        assert_no_enqueued_jobs(only: OnboardingCleanupJob) do
          OnboardingCleanupJob.perform_now(user.id, session.session_id, OnboardingCleanupJob::RETRY_DELAYS.length)
        end
        assert Creative.exists?(session.root.id)

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id ]) do
          task.update!(status: "done")
        end

        OnboardingCleanupJob.perform_now(user.id, session.session_id)
        refute Creative.exists?(session.root.id)
      end
    end
  end
end
