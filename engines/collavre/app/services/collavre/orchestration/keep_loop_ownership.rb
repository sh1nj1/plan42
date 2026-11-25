# frozen_string_literal: true

module Collavre
  module Orchestration
    # Queue acknowledgements bridge publication to Task creation. They are
    # leases, not permanent owners: the queue is authoritative after the grace.
    class KeepLoopOwnership
      JOB_CLASSES = %w[Collavre::AiAgentJob Collavre::TriggerLoopCheckJob Collavre::TriggerLoopVerifyJob Collavre::InlineAgentReplayJob].freeze

      def initialize(creative, grace:)
        @creative = creative
        @config = creative.data.dig("trigger", "loop")
        @comment_id = @config["current_comment_id"]
        @grace = grace
      end

      def activity_at
        ([ @creative.updated_at, reservation_time ] + tasks.map(&:updated_at)).compact.max
      end

      def live?
        active = active_task_owner?
        return true if active && reservation.blank? && tasks.none?(&:pending?)

        queued = executable_jobs.any? { |name, args| owns_job?(name, args) }
        pending = pending_task_owner?
        retire_expired_claims unless queued
        prune_reservations unless queued
        active || pending || queued || fresh_reservation? || fresh_restoration_owner?
      end

      private

      def active_task_owner?
        tasks.any? { |task| @creative.trigger_loop_task?(task) && task.active? && !task.pending? }
      end

      def fresh_restoration_owner?
        tasks.any? { |task| pending_restore?(task) && task.updated_at > @grace.ago }
      end

      def tasks
        @tasks ||= Task.where(creative_id: @creative.id, topic_id: @config["trigger_topic_id"], trigger_event_name: KeepLoop::TURN_EVENTS)
                       .select { |task| KeepLoop.turn?(task) }
      end

      def reservation
        entry = @creative.data.dig("trigger", KeepQueuedDispatches::KEY)
        entry if entry&.dig("comment_id") == @comment_id &&
          KeepLoop.admit!(@creative, generation: entry["generation"], comment_id: @comment_id)
      end

      def reservation_time
        value = reservation&.dig("reserved_at")
        value ? Time.iso8601(value) : @creative.updated_at
      end

      def fresh_reservation?
        reservation.present? && reservation_time > @grace.ago
      end

      def pending_restore?(task)
        DeliveryRecord.pending_restoration?(task, comment_id: @comment_id)
      end

      def retire_expired_claims
        tasks.each do |task|
          next unless task.updated_at <= @grace.ago && pending_restore?(task)

          DeliveryRecord.release_restore_claim!(task, @comment_id)
          DeliveryRecord.reject_restore!(task, @comment_id)
          task.reload
        end
      end

      def prune_reservations
        return if fresh_reservation?

        @creative.data["trigger"].delete(KeepQueuedDispatches::KEY)
      end

      def pending_task_owner?
        tasks.map do |task|
          next false unless task.pending? && KeepLoop.turn_generation(task.trigger_event_payload)
          live = task.updated_at > @grace.ago || executable_jobs.any? do |name, args|
            name == "Collavre::AiAgentJob" && task_id(args.first) == task.id
          end
          if live
            @creative.trigger_loop_task?(task)
          else
            task.cancel_if_active!(statuses: [ "pending" ])
            false
          end
        end.any?
      end

      def executable_jobs
        @executable_jobs ||= case adapter = AiAgentJob.queue_adapter
        when ActiveJob::QueueAdapters::TestAdapter
          adapter.enqueued_jobs.map { |job| [ job[:job].name, job[:args] ] }
        when ActiveJob::QueueAdapters::InlineAdapter
          []
        when ActiveJob::QueueAdapters::SolidQueueAdapter
          solid_queue_jobs.filter_map { |job| [ job.class_name, job.arguments.fetch("arguments") ] if executable?(job) }
        else
          raise NotImplementedError, "Keep reconciliation requires queue ownership evidence for #{adapter.class}"
        end
      end

      def solid_queue_jobs
        # Only orphan candidates inspect the queue; active Task owners need no
        # queue scan unless a reservation also needs retirement.
        SolidQueue::Job.where(class_name: JOB_CLASSES, finished_at: nil)
          .includes(:ready_execution, :scheduled_execution, :blocked_execution, claimed_execution: :process)
      end

      def executable?(job)
        return true if job.ready_execution || job.scheduled_execution || job.blocked_execution

        process = job.claimed_execution&.process
        process && process.last_heartbeat_at > SolidQueue.process_alive_threshold.ago
      end

      def owns_job?(name, args)
        case name
        when "Collavre::AiAgentJob"
          context = args[2]
          return args.first.is_a?(Hash) && owns_task?(args.first) unless context.is_a?(Hash)

          generation = context.dig("comment", "keep_loop_generation")
          context.dig("creative", "id") == @creative.id && context.dig("comment", "id") == @comment_id &&
            KeepLoop.admit!(@creative, generation: generation, comment_id: context.dig("comment", "id"))
        when "Collavre::TriggerLoopCheckJob", "Collavre::TriggerLoopVerifyJob"
          owns_task?(args.first)
        when "Collavre::InlineAgentReplayJob"
          task_id = args[2] || Comment.where(id: args.first).pick(:task_id)
          owns_task?(task_id)
        else
          false
        end
      end

      def owns_task?(value)
        tasks.any? { |task| task.id == task_id(value) && @creative.trigger_loop_task?(task) }
      end

      def task_id(value)
        value.is_a?(Hash) ? GlobalID.parse(value["_aj_globalid"])&.model_id&.to_i : value
      end
    end
  end
end
