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

      test "a terminal turn enqueues one cleanup for two creatives in the same session" do
        user = User.create!(name: "One cleanup", email: "one-cleanup@example.com", password: "password")
        session = Seeder.new(user: user).call
        comment = Comment.create!(creative: session.practice_creatives.second, user: user, content: "Help")
        task = Task.create!(name: "Response", status: "running", creative: session.practice_creatives.first,
                            agent: users(:ai_bot), trigger_event_payload: { "comment" => { "id" => comment.id } })
        CompletionService.new(user: user).call(defer_pending_agent_cleanup: true)
        clear_enqueued_jobs
        assert_enqueued_jobs 1, only: OnboardingCleanupJob do
          task.update!(status: "done")
        end
      end

      test "empty cleanup does not inspect the task or job queues" do
        service = CompletionService.new(user: users(:one))
        service.stub(:queued_agent_job_for_comments?, ->(*) { flunk "must not scan jobs" }) do
          assert service.clean_up_when_agent_turn_settles("missing")
        end
      end

      test "terminal turn outside the session retries cleanup through its trigger comment" do
        user = User.create!(name: "External context", email: "external-context@example.com", password: "password")
        session = Seeder.new(user: user).call
        comment = Comment.create!(creative: session.practice_creatives.second, user: user, content: "Help")
        outside = Creative.create!(user: user, description: "Outside context")
        task = Task.create!(name: "Response", status: "running", creative: outside, agent: users(:ai_bot),
                            trigger_event_payload: { "comment" => { "id" => comment.id.to_s } })
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
        assert Creative.exists?(outside.id)
      end

      test "reset preserves legacy metadata with and without a genuine session" do
        user = User.create!(name: "Legacy", email: "legacy-reset@example.com", password: "password")
        scalar = Creative.create!(user: user, description: "Scalar", data: { "onboarding" => "legacy" })
        legacy = Creative.create!(user: user, description: "Legacy", data: {
          "onboarding" => { "seeded" => true, "scenario_key" => "first_steps", "session_id" => "old" }
        })
        service = CompletionService.new(user: user)
        assert service.call
        assert Creative.exists?(scalar.id)
        assert Creative.exists?(legacy.id)

        session = Seeder.new(user: user, force: true).call
        copied = Creative.create!(user: user, description: "Copied", data: session.root.data)
        assert service.call
        refute Creative.exists?(session.root.id)
        [ scalar, legacy, copied ].each { |creative| assert Creative.exists?(creative.id) }
      end

      test "terminal task ignores scalar and untrusted onboarding metadata" do
        user = users(:one)
        [ "legacy", { "session_id" => "legacy", "cleanup_pending" => true } ].each do |metadata|
          creative = Creative.create!(user: user, description: "Legacy", data: { "onboarding" => metadata })
          task = Task.create!(name: "Ordinary turn", status: "running", creative: creative, agent: users(:ai_bot))
          assert_no_enqueued_jobs(only: OnboardingCleanupJob) { task.update!(status: "done") }
          assert task.reload.done?
        end
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

      %i[finish reset deferred].each do |cleanup|
        test "#{cleanup} reparents preserved descendants to the surviving workspace" do
          user = User.create!(name: "Hierarchy", email: "hierarchy@example.com", password: "password")
          session = Seeder.new(user: user).call
          workspace = Creative.create!(user: user, description: "Workspace")
          session.root.update!(parent: workspace)
          practice = session.practice_creatives.first
          nested = session.practice_creatives.second
          nested.update!(parent: practice)
          preserved = [ session.root, practice, nested ].map do |parent|
            Creative.create!(user: user, parent: parent, description: "Keep me")
          end
          grandchild = Creative.create!(user: user, parent: preserved.last, description: "Keep hierarchy")
          owned_ids = [ session.root.id, practice.id, nested.id ]
          service = CompletionService.new(user: user)

          case cleanup
          when :finish then assert service.call(session_id: session.session_id)
          when :reset
            assert service.call(session_id: session.session_id, defer_pending_agent_cleanup: true)
            user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
            Seeder.new(user: user, force: true).call
          when :deferred then assert service.clean_up_when_agent_turn_settles(session.session_id)
          end

          assert_empty Creative.where(id: owned_ids)
          preserved.each { |item| assert_equal workspace.id, item.reload.parent_id }
          assert_equal preserved.last.id, grandchild.reload.parent_id
          assert_equal [ workspace.id, preserved.last.id ].sort, grandchild.ancestors.ids.sort
        end
      end

      test "cleanup reparenting skips drop triggers while ordinary moves still trigger" do
        user = User.create!(name: "Quiet cleanup", email: "quiet-cleanup@example.com", password: "password")
        session = Seeder.new(user: user).call
        workspace = Creative.create!(user: user, description: "Triggered workspace",
                                     data: { "trigger" => { "on_child_enter" => true } })
        session.root.update!(parent: workspace)
        preserved = Creative.create!(user: user, parent: session.root, description: "Keep", progress: 1.0)
        clear_enqueued_jobs

        assert_no_enqueued_jobs(only: DropTriggerJob) { CompletionService.new(user: user).call }

        assert_equal workspace.id, preserved.reload.parent_id
        assert_equal [ workspace.id ], preserved.ancestors.ids
        assert_equal 1.0, workspace.reload.progress
        preserved.update!(parent: nil)
        assert_enqueued_with(job: DropTriggerJob, args: [ workspace.id, preserved.id ]) do
          preserved.update!(parent: workspace)
        end
      end

      test "failed reparenting rolls back earlier deletions and preserves the session" do
        user = User.create!(name: "Rollback", email: "rollback@example.com", password: "password")
        session = Seeder.new(user: user).call
        workspace = Creative.create!(user: user, description: "Workspace")
        session.root.update!(parent: workspace)
        preserved = Creative.create!(user: user, parent: session.root, description: "Keep me")
        owned_ids = [ session.root.id, *session.practice_creative_ids ]
        reject_move = proc { throw(:abort) if id == preserved.id && parent_id == workspace.id }
        Creative.set_callback(:update, :before, reject_move)

        assert_raises(ActiveRecord::RecordNotSaved) { CompletionService.new(user: user).call }

        assert_equal owned_ids.sort, Creative.where(id: owned_ids).ids.sort
        assert_equal session.root.id, preserved.reload.parent_id
        assert_nil user.reload.onboarding_completed_at
      ensure
        Creative.skip_callback(:update, :before, reject_move) if reject_move
      end

      test "cleanup of an older tagged shell preserves the origin hierarchy" do
        user = User.create!(name: "Linked cleanup", email: "linked-cleanup@example.com", password: "password")
        session = Seeder.new(user: user).call
        workspace = Creative.create!(user: user, description: "Workspace")
        session.root.update!(parent: workspace)
        origin = Creative.create!(user: user, description: "Origin")
        child = Creative.create!(user: user, parent: origin, description: "Origin child")
        shell = Creative.create!(user: user, parent: session.root, origin: origin)
        Ownership.stamp!(shell, session.session_id)

        assert CompletionService.new(user: user).call

        refute Creative.exists?(shell.id)
        assert_equal origin.id, child.reload.parent_id
        assert_equal [ origin.id ], child.ancestors.ids
      end

      test "removes the practice item added to complete the progress step" do
        user = User.create!(name: "Added practice finisher", email: "added-practice-finisher@example.com", password: "password")
        session = Seeder.new(user: user).call
        added = Creative.create!(user: user, parent: session.root, description: "Added practice item")

        ProgressTracker.record(user: user, event: :creative_created, creative: added)
        CompletionService.new(user: user).call

        refute Creative.exists?(added.id)
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

      test "defers cleanup for a residual active task after its trigger moved" do
        user = User.create!(name: "Moved comment finisher", email: "moved-comment-finisher@example.com", password: "password")
        agent = User.create!(name: "Moved comment helper", email: "moved-comment-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        creative = session.practice_creatives.second
        comment = Comment.create!(creative: creative, user: user, content: "@Moved comment helper: Please help")
        task = Task.create!(name: "Response", status: "running", trigger_event_name: "comment_created",
                            trigger_event_payload: { "comment" => { "id" => comment.id } }, agent: agent, creative: creative)
        destination = Creative.create!(user: user, description: "Outside onboarding")
        comment.update!(creative: destination)
        # A worker may still be settling an earlier dispatch after revocation.
        task.update_columns(status: "running")

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id ]) do
          CompletionService.new(user: user).call(defer_pending_agent_cleanup: true)
        end

        assert Creative.exists?(session.root.id)
        assert_equal "running", task.reload.status
      end

      test "defers cleanup for an active agent turn after its onboarding root is deleted" do
        user = User.create!(name: "Deleted root awaiting finisher", email: "deleted-root-awaiting@example.com", password: "password")
        agent = User.create!(name: "Deleted root helper", email: "deleted-root-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        creative = session.practice_creatives.second
        comment = Comment.create!(creative: creative, user: user, content: "@Deleted root helper: Please help")
        task = Task.create!(name: "Response", status: "running", trigger_event_name: "comment_created",
                            trigger_event_payload: { "comment" => { "id" => comment.id } }, agent: agent, creative: creative)
        Creatives::DestroyService.new(creative: session.root, user: user).call

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id ]) do
          Seeder.new(user: user).call
        end

        assert Creative.exists?(creative.id)
        assert_equal "running", task.reload.status
      end

      test "defers each orphaned session independently when multiple session roots are deleted" do
        user = User.create!(name: "Multiple deleted roots", email: "multiple-deleted-roots@example.com", password: "password")
        agent = User.create!(name: "Multiple deleted roots helper", email: "multiple-deleted-roots-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        retired_session = Seeder.new(user: user).call
        retired_creative = retired_session.practice_creatives.second
        comment = Comment.create!(creative: retired_creative, user: user, content: "@Multiple deleted roots helper: Please help")
        task = Task.create!(name: "Response", status: "running", trigger_event_name: "comment_created",
                            trigger_event_payload: { "comment" => { "id" => comment.id } }, agent: agent, creative: retired_creative)

        CompletionService.new(user: user).call(session_id: retired_session.session_id, defer_pending_agent_cleanup: true)
        retired_session.root.reload.update!(data: retired_session.root.data.merge("onboarding" => retired_session.data.except("scenario_key")))
        user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
        active_session = Seeder.new(user: user, force: true).call
        active_practice_ids = active_session.practice_creatives.ids
        Creatives::DestroyService.new(creative: active_session.root, user: user).call

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, retired_session.session_id ]) do
          Seeder.new(user: user).call
        end

        assert Creative.exists?(retired_creative.id)
        assert_equal "running", task.reload.status
        assert_empty user.creatives.where(id: active_practice_ids)
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

      test "defers cleanup while a queued job retains a moved onboarding comment's creative" do
        user = User.create!(name: "Moved queued finisher", email: "moved-queued-finisher@example.com", password: "password")
        agent = User.create!(name: "Moved queued helper", email: "moved-queued-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        creative = session.practice_creatives.second
        comment = Comment.create!(creative: creative, user: user, content: "@Moved queued helper: Please help")
        ai_job = AiAgentJob.new(agent.id, "comment_created", comment.dispatch_payload)
        SolidQueue::Job.create!(class_name: AiAgentJob.name, queue_name: "ai_agents", arguments: ai_job.serialize)
        comment.update!(creative: Creative.create!(user: user, description: "Outside onboarding"))

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id ]) do
          CompletionService.new(user: user).call(defer_pending_agent_cleanup: true)
        end

        assert Creative.exists?(session.root.id)
      end

      test "queued replay contexts defer cleanup without deserializing unrelated jobs" do
        user = User.create!(name: "Queued replay", email: "queued-replay@example.com", password: "password")
        session = Seeder.new(user: user).call
        creative = session.practice_creatives.second
        comment = Comment.create!(creative: creative, user: user, content: "Help")
        job = AiAgentJob.new(users(:ai_bot).id, "comment_created", comment.dispatch_payload, "replay-identity")
        queued = SolidQueue::Job.create!(class_name: AiAgentJob.name, queue_name: "ai_agents", arguments: job.serialize)
        unrelated = AiAgentJob.new(users(:ai_bot).id, "comment_created", { "creative" => { "id" => -1 } })
        SolidQueue::Job.create!(class_name: AiAgentJob.name, queue_name: "ai_agents", arguments: unrelated.serialize)
        service = CompletionService.new(user: user)
        refute service.clean_up_when_agent_turn_settles(session.session_id)
        queued.update!(finished_at: Time.current)
        assert service.clean_up_when_agent_turn_settles(session.session_id)
        refute Creative.exists?(session.root.id)
      end

      test "checks queued agent jobs before active tasks during cleanup" do
        user = User.create!(name: "Cleanup ordering", email: "cleanup-ordering@example.com", password: "password")
        session = Seeder.new(user: user).call
        Comment.create!(creative: session.practice_creatives.second, user: user, content: "Please help")
        service = CompletionService.new(user: user)
        checks = []

        service.stub(:queued_agent_job_for_comments?, ->(_comment_ids, _creative_ids) { checks << :queued; false }) do
          service.stub(:active_task_for_comments?, ->(_comment_ids, _creative_ids) { checks << :active; false }) do
            refute service.send(:pending_agent_turn?, session.practice_creatives)
          end
        end

        assert_equal [ :queued, :active ], checks
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

      test "replays cleanup after an externally claimed onboarding task settles beyond the retry window" do
        user = User.create!(name: "External claim finisher", email: "external-claim-finisher@example.com", password: "password")
        agent = User.create!(name: "External claim helper", email: "external-claim-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        creative = session.practice_creatives.second
        topic = creative.topics.create!(name: "External claim", user: user)
        comment = Comment.create!(creative: creative, user: user, content: "Please help")
        task = Task.create!(name: "External response", status: "delegated", agent: agent,
                            trigger_event_payload: { "comment" => { "id" => comment.id } },
                            creative: creative, topic_id: topic.id)

        CompletionService.new(user: user).call(defer_pending_agent_cleanup: true)
        clear_enqueued_jobs
        OnboardingCleanupJob.perform_now(user.id, session.session_id, OnboardingCleanupJob::RETRY_DELAYS.length)

        claimed_task = AiAgent::TaskClaimService.new.claim(agent: agent, topic: topic, requested_task_id: task.id)

        assert_equal "running", claimed_task.reload.status
        refute CompletionService.new(user: user).clean_up_when_agent_turn_settles(session.session_id)
        assert Creative.exists?(session.root.id)

        reply = Comment.create!(creative: creative, topic: topic, user: agent, content: "I can help")

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id ]) do
          claim_service = AiAgent::TaskClaimService.new
          claim_service.link_reply(task: claimed_task, comment: reply)
          claim_service.finalize(agent: agent, task: claimed_task, comment: reply)
        end
      end
    end
  end
end
