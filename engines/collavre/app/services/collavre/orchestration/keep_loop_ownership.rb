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
        active = tasks.any? { |task| @creative.trigger_loop_task?(task) && task.active? }
        return true if active && reservation.blank?

        queued = queued?
        retire_expired_claims unless queued
        prune_reservations unless queued
        active || queued || fresh_reservation? || tasks.any? { |task| pending_restore?(task) && task.updated_at > @grace.ago }
      end

      private

      def tasks
        @tasks ||= Task.where(creative_id: @creative.id, topic_id: @config["trigger_topic_id"], trigger_event_name: "comment_created").to_a
      end

      def reservation
        entry = @creative.data.dig("trigger", KeepQueuedDispatches::KEY)
        entry if entry&.dig("comment_id") == @comment_id
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

      def queued?
        adapter = AiAgentJob.queue_adapter
        case adapter
        when ActiveJob::QueueAdapters::TestAdapter
          adapter.enqueued_jobs.any? { |job| owns_job?(job[:job].name, job[:args]) }
        when ActiveJob::QueueAdapters::InlineAdapter
          false
        when ActiveJob::QueueAdapters::SolidQueueAdapter
          solid_queue_jobs.any? { |job| executable?(job) && owns_job?(job.class_name, job.arguments.fetch("arguments")) }
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
            generation&.slice("start_comment_id", "current_comment_id", "trigger_topic_id") ==
              @config.slice("start_comment_id", "current_comment_id", "trigger_topic_id")
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
        id = value.is_a?(Hash) ? GlobalID.parse(value["_aj_globalid"])&.model_id&.to_i : value
        tasks.any? { |task| task.id == id && @creative.trigger_loop_task?(task) }
      end
    end
  end
end
