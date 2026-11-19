# frozen_string_literal: true

require "test_helper"

module Collavre
  class KeepLoopReconcileJobTest < ActiveJob::TestCase
    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @creative = creatives(:tshirt)
      @user = users(:one)
      @agent = users(:ai_bot)
      @topic = @creative.main_topic
      CreativeShare.find_or_create_by!(creative: @creative, user: @agent).update!(permission: :feedback)
      CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
      Orchestration::ResourceTracker.for(@agent).reset!
      @turn = @creative.comments.create!(user: @user, topic: @topic, content: "Keep working", skip_dispatch: true)
      @config = TriggerLoopConfig.build(@topic.id, source: "keep", start_comment_id: @turn.id,
        current_comment_id: @turn.id, agent_id: @agent.id, current_iteration: 2, cooldown_seconds: 0)
      @creative.update!(data: { "trigger" => { "loop" => @config, "unrelated" => "preserved" } })
      @context = @turn.reload.dispatch_payload.deep_stringify_keys
      @task = Task.create!(creative: @creative, topic_id: @topic.id, agent: @agent, name: "Keep task", status: :running,
        trigger_event_name: "comment_created", trigger_event_payload: @context)
      @task.update_columns(status: "done")
      @reply = @creative.comments.create!(user: @agent, task: @task, topic: @topic, content: "[STATUS: CONTINUE]", skip_dispatch: true)
      clear_enqueued_jobs
    end

    teardown do
      ActiveJob::Base.queue_adapter = @previous_adapter
    end

    test "ownerless turn and a lost verification recover once without consuming an iteration" do
      %w[running pending_verification].each do |state|
        set_state(state)
        recover_after_grace
        assert_equal "awaiting_user", config["state"]
        assert_equal 2, config["current_iteration"]
        before = @creative.data.deep_dup
        KeepLoopReconcileJob.perform_now
        assert_equal before, @creative.reload.data
        assert_equal "preserved", @creative.data.dig("trigger", "unrelated")
      end
    end

    test "fresh turn is allowed its grace and ownership reappearance resets observation" do
      KeepLoopReconcileJob.perform_now
      assert_equal "running", config["state"]
      assert @creative.data.dig("trigger", KeepLoopReconcileJob::RECOVERY_KEY)
      @task.update_columns(status: "queued")
      KeepLoopReconcileJob.perform_now
      assert_nil @creative.reload.data.dig("trigger", KeepLoopReconcileJob::RECOVERY_KEY)
      @task.update_columns(status: "done")
      recover_after_grace
      assert_equal "awaiting_user", config["state"]
    end

    (Task::ACTIVE_STATUSES - [ "pending" ]).each do |status|
      test "#{status} same-turn task keeps ownership beyond the grace" do
        @task.update_columns(status: status)
        recover_after_grace
        assert_equal "running", config["state"]
      end
    end

    test "unrelated task does not own this turn" do
      @task.update_columns(status: "running", trigger_event_payload: { "comment" => { "id" => @turn.id + 100 } })
      recover_after_grace
      assert_equal "awaiting_user", config["state"]
    end

    test "discarded reservation is retired but an executable sibling retains ownership" do
      Orchestration::KeepQueuedDispatches.reserve!(@context, @agent)
      AiAgentJob.perform_later(@agent.id, "comment_created", @context)
      recover_after_grace
      assert_equal "running", config["state"]
      clear_enqueued_jobs
      recover_after_grace
      assert_equal "awaiting_user", config["state"]
      assert_nil @creative.data.dig("trigger", Orchestration::KeepQueuedDispatches::KEY)
    end

    test "check verify promoted waiter and login replay jobs own their current turn" do
      [ TriggerLoopCheckJob.new(@task.id), TriggerLoopVerifyJob.new(@task.id),
        AiAgentJob.new(@task), InlineAgentReplayJob.new(@reply.id, @user.id, @task.id),
        InlineAgentReplayJob.new(@reply.id, @user.id) ].each do |job|
        clear_enqueued_jobs
        job.enqueue
        recover_after_grace
        assert_equal "running", config["state"], job.class.name
      end
    end

    test "stale queue context and unrelated jobs cannot hold the turn" do
      AiAgentJob.perform_later(@agent.id, "comment_created", @context.deep_merge("comment" => { "id" => @turn.id + 1 }))
      CreativeBroadcastJob.perform_later(@creative.id)
      recover_after_grace
      assert_equal "awaiting_user", config["state"]
    end

    test "queue errors defer recovery and preserve reservation and counters" do
      Orchestration::KeepQueuedDispatches.reserve!(@context, @agent)
      before = @creative.reload.data.deep_dup
      adapter = Object.new
      AiAgentJob.stub(:queue_adapter, adapter) { recover_after_grace }
      assert_equal before, @creative.reload.data
    end

    test "fresh restoration is owned and abandoned restoration is retired" do
      cover_current_turn
      KeepLoopReconcileJob.perform_now
      assert_equal "running", config["state"]
      recover_after_grace
      assert_equal "awaiting_user", config["state"]
      assert_includes Orchestration::DeliveryRecord.rejected_restore_ids_in(@task.reload.trigger_event_payload), @turn.id
      refute Orchestration::DeliveryRecord.pending_restoration?(@task, comment_id: @turn.id)
    end

    test "a concurrent pause or replacement is preserved by the snapshot check" do
      %w[paused replacement].each do |action|
        set_state("running")
        original = Comments::TopicMutation.method(:call)
        wrap = lambda do |*args, &block|
          replacement = @config.merge("state" => action == "paused" ? "paused" : "running", "goal" => action)
          @creative.update!(data: { "trigger" => { "loop" => replacement } })
          original.call(*args, &block)
        end
        Comments::TopicMutation.stub(:call, wrap) { recover_after_grace }
        assert_equal action, config["goal"]
        assert_equal action == "paused" ? "paused" : "running", config["state"]
      end
    end

    %i[ready scheduled blocked claimed expired_claim failed discarded finished].each do |state|
      test "Solid Queue #{state} supplies only executable ownership" do
        travel 16.minutes do
          job = SolidQueue::Job.enqueue(AiAgentJob.new(@agent.id, "comment_created", @context),
            scheduled_at: state == :scheduled ? 1.day.from_now : Time.current)
          case state
          when :blocked
            job.ready_execution.destroy!
            job.update!(concurrency_key: "keep-test")
            SolidQueue::BlockedExecution.create!(job: job, queue_name: "ai_agents", priority: 0,
              concurrency_key: "keep-test", expires_at: 1.day.from_now)
          when :claimed, :expired_claim
            job.ready_execution.destroy!
            process = SolidQueue::Process.register(kind: "Worker", pid: 12345, hostname: "example.test", name: SecureRandom.uuid)
            process.update!(last_heartbeat_at: 1.hour.ago) if state == :expired_claim
            SolidQueue::ClaimedExecution.create!(job: job, process: process)
          when :failed
            job.ready_execution.destroy!
            SolidQueue::FailedExecution.create!(job: job, exception: RuntimeError.new("worker failed"))
          when :discarded then job.destroy!
          when :finished then job.update!(finished_at: Time.current)
          end
          AiAgentJob.stub(:queue_adapter, ActiveJob::QueueAdapters::SolidQueueAdapter.new) { KeepLoopReconcileJob.perform_now }
          expected = %i[ready scheduled blocked claimed].include?(state) ? "running" : "awaiting_user"
          assert_equal expected, config["state"]
        end
      end
    end

    %i[ready scheduled claimed expired_claim failed discarded].each do |state|
      test "pending promotion with #{state} job needs executable queue evidence" do
        @task.update_columns(status: "pending")
        KeepLoopReconcileJob.perform_now
        assert_equal "running", config["state"], "Fresh publication has its grace"
        travel 16.minutes do
          job = SolidQueue::Job.enqueue(AiAgentJob.new(@task), scheduled_at: state == :scheduled ? 1.day.from_now : Time.current)
          if %i[claimed expired_claim failed].include?(state)
            job.ready_execution.destroy!
            if state == :failed
              SolidQueue::FailedExecution.create!(job: job, exception: RuntimeError.new("worker failed"))
            else
              process = SolidQueue::Process.register(kind: "Worker", pid: 12345, hostname: "example.test", name: SecureRandom.uuid)
              process.update!(last_heartbeat_at: 1.hour.ago) if state == :expired_claim
              SolidQueue::ClaimedExecution.create!(job: job, process: process)
            end
          elsif state == :discarded
            job.destroy!
          end
          AiAgentJob.stub(:queue_adapter, ActiveJob::QueueAdapters::SolidQueueAdapter.new) { KeepLoopReconcileJob.perform_now }
          live = %i[ready scheduled claimed].include?(state)
          assert_equal live ? "running" : "awaiting_user", config["state"]
          assert_equal live ? "pending" : "cancelled", @task.reload.status
          assert_equal 2, config["current_iteration"]
        end
      end
    end

    test "queue database failure is not evidence of owner absence" do
      before = @creative.reload.data.deep_dup
      SolidQueue::Job.stub(:where, ->(*) { raise ActiveRecord::ConnectionNotEstablished }) do
        AiAgentJob.stub(:queue_adapter, ActiveJob::QueueAdapters::SolidQueueAdapter.new) { recover_after_grace }
      end
      assert_equal before, @creative.reload.data
    end

    test "a live sibling retains the loop while an orphaned pending slot is cancelled" do
      @task.update_columns(status: "pending")
      sibling = @task.dup
      sibling.assign_attributes(status: "running")
      sibling.save!
      recover_after_grace
      assert_equal "cancelled", @task.reload.status
      assert_equal "running", sibling.reload.status
      assert_equal "running", config["state"]
    end

    test "configured grace overrides the default and invalid values use the default" do
      SystemSetting.stub(:cached_value, 30) do
        travel 31.seconds do
          KeepLoopReconcileJob.perform_now
          assert_equal "awaiting_user", config["state"]
        end
      end
      set_state("running")
      SystemSetting.stub(:cached_value, 0) do
        travel 1.minute do
          KeepLoopReconcileJob.perform_now
          assert_equal "running", config["state"]
        end
        recover_after_grace
        assert_equal "awaiting_user", config["state"]
      end
    end

    # Every dispatch entry uses its real lifecycle code; only the external queue
    # failure is injected. The sweep is the backstop when callbacks cannot help.
    %i[initial continuation infrastructure_retry failed_verification resume restart public_reply restoration login_replay promotion]
      .product(%i[raise false execution_rejection permission_revocation deletion pause]).each do |entry, failure|
      next if entry == :promotion && failure == :raise

      test "#{entry} with #{failure} cannot remain running after one recovery" do
        prepare_entry(entry)
        if %i[raise false].include?(failure)
          queue = entry == :login_replay ? InlineAgentReplayJob : AiAgentJob
          attempted = false
          publish = lambda do |*|
            attempted = true
            failure == :raise ? raise(ActiveJob::EnqueueError) : false
          end
          queue.stub(:perform_later, publish) { attempt_entry(entry) }
          assert attempted, "The real entry must reach the injected enqueue failure"
        else
          attempt_entry(entry)
          apply_execution_failure(failure)
        end
        before = config&.dig("current_iteration")
        clear_enqueued_jobs
        recover_after_grace
        refute_equal "running", config&.dig("state")
        assert_equal before, config&.dig("current_iteration") if config
      end
    end

    test "failed promotion publication requeues a live waiter instead of orphaning it" do
      prepare_entry(:promotion)
      AiAgentJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError }) { attempt_entry(:promotion) }
      assert_equal "queued", @task.reload.status
      recover_after_grace
      assert_equal "running", config["state"]
    end

    test "promoting an old waiter starts a fresh publication grace before enqueue" do
      prepare_entry(:promotion)
      @task.update_columns(updated_at: 1.hour.ago)
      AiAgentJob.stub(:perform_later, ->(*) {
        KeepLoopReconcileJob.perform_now
        assert_equal "pending", @task.reload.status
        assert_equal "running", config["state"]
        false
      }) { attempt_entry(:promotion) }
      recover_after_grace
      assert_equal "cancelled", @task.reload.status
      assert_equal "awaiting_user", config["state"]
    end

    private

    def config = @creative.reload.data.dig("trigger", "loop")

    def set_state(state)
      @creative.update!(data: @creative.reload.data.deep_merge("trigger" => { "loop" => @config.merge("state" => state) }))
    end

    def recover_after_grace
      travel 16.minutes do
        KeepLoopReconcileJob.perform_now
      end
    end

    def cover_current_turn
      anchor = @creative.comments.create!(user: @user, topic: @topic, content: "Covering", skip_dispatch: true)
      @task.update_columns(status: "running", trigger_event_payload: anchor.dispatch_payload.deep_stringify_keys)
      Orchestration::DeliveryRecord.claim_drop!(@task, @turn.id, context: @context)
      @task.update_columns(status: "failed")
      @task.reload
    end

    def prepare_entry(entry)
      case entry
      when :initial, :resume then set_state("paused")
      when :restart then set_state("completed")
      when :public_reply then set_state("awaiting_user")
      when :infrastructure_retry then @reply.update!(content: "Connection timed out")
      when :failed_verification then set_state("pending_verification")
      when :restoration then cover_current_turn
      when :login_replay then prepare_login
      when :promotion then @task.update_columns(status: "queued")
      end
      clear_enqueued_jobs
    end

    def attempt_entry(entry)
      case entry
      when :initial
        comment = @creative.comments.build(user: @user, topic: @topic, content: "/keep @#{@agent.name}: Continue")
        assert_nil Comments::KeepCommand.new(comment: comment, user: @user).call
        comment.save!
      when :continuation, :infrastructure_retry then TriggerLoopCheckJob.perform_now(@task.id)
      when :failed_verification
        job = TriggerLoopVerifyJob.new
        job.stub(:verify_completion, :continue) { job.perform(@task.id) }
      when :resume, :restart
        Creatives::TriggerActionCommand.new(creative: @creative.reload, user: @user, action: entry.to_s).call
      when :public_reply
        @creative.comments.create!(user: @user, topic: @topic, content: "Continue please")
      when :restoration then Orchestration::DeliveryRecord.restore!(@task)
      when :login_replay then CliProxy::InlineLogin.new(@reply, @user).resume!
      when :promotion then Orchestration::AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
      end
    rescue ActiveJob::EnqueueError, CliProxy::Client::Error
      nil
    end

    def apply_execution_failure(failure)
      case failure
      when :pause
        Creatives::TriggerActionCommand.new(creative: @creative.reload, user: @user, action: "pause").call
      when :deletion
        Comment.find_by(id: config["current_comment_id"])&.destroy!
      when :permission_revocation
        CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: :no_access)
        execute_dispatches
      when :execution_rejection
        Orchestration::Matcher.stub(:prepare_waiting_payload, nil) { execute_dispatches }
      end
    end

    def execute_dispatches
      jobs = enqueued_jobs.select { |job| [ AiAgentJob, InlineAgentReplayJob ].include?(job[:job]) }.dup
      assert jobs.any?, "The real entry must publish a dispatch before execution rejection"
      jobs.each { |job| job[:job].new.perform(*ActiveJob::Arguments.deserialize(job[:args])) }
    end

    def prepare_login
      @turn.update!(content: "@#{@agent.name}: Keep working")
      gateway = AgentGateway.create!(owner: @user, name: "Recovery proxy", base_url: "https://proxy.example.com",
        admin_key: "admin", completion_key: "completion", identity_secret: "x" * 32, workspace_mode: :per_user)
      @agent.update!(llm_vendor: "cli_proxy", llm_model: "paperclip/codex_local", created_by_id: @user.id, agent_gateway: gateway)
      workspace = AgentWorkspace.resolve!(agent: @agent, user: @user)
      @task.update_columns(trigger_event_payload: @context.merge("workspace_user_id" => @user.id,
        "engine_login" => { "engine" => "codex", "workspace_id" => workspace.id, "retryable" => true,
          "authorized" => true, "session_user_id" => @user.id }))
      @task.reload
    end
  end
end
