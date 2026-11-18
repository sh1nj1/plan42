# frozen_string_literal: true

module Collavre
  # Writes the jobs enqueued inside a block to the queue in as few bulk inserts
  # as possible, instead of one queue transaction per perform_later.
  #
  #   Collavre::BulkJobEnqueue.collect(deferrable: %w[SomeJob]) { ... }
  #
  # Jobs whose class name is listed in +deferrable+ are fire-and-forget: their
  # perform_later returns immediately and the job is written when the next
  # flush happens (at the latest when the block ends). Every other job flushes
  # the pending ones together with itself right away, so callers that check
  # +successfully_enqueued?+ still get the real outcome. Either way jobs are
  # written in the order they were enqueued, each job's enqueue callbacks (and
  # with them Active Job's enqueue instrumentation) wrap its actual write, and
  # a failed bulk insert falls back to enqueuing the jobs one by one so each
  # job gets the adapter's ordinary error handling.
  #
  # Jobs that the adapter can't bulk insert, or that defer themselves until
  # after the surrounding transaction commits, keep the regular path. So does
  # everything on Rails versions before 8.1, where enqueue runs the callbacks
  # around raw_enqueue itself and there is no _raw_enqueue to write with.
  module BulkJobEnqueue
    STATE_KEY = :collavre_bulk_job_enqueue

    Scope = Struct.new(:deferrable, :pending)

    module_function

    def collect(deferrable: [])
      return yield if current || !supported?

      run_scope(Scope.new(deferrable.map(&:to_s).to_set, [])) { yield }
    end

    # Rails 8.1 moved the enqueue callbacks into raw_enqueue and the actual
    # write into _raw_enqueue; collecting relies on that split.
    def supported?
      ActiveJob::Base.private_method_defined?(:_raw_enqueue)
    end

    def current
      ActiveSupport::IsolatedExecutionState[STATE_KEY]
    end

    # Called by JobExtension for each job enqueued while a scope is active.
    # Returns false when the job must take the regular enqueue path.
    def capture(job, scope)
      unless bulk_insertable?(job)
        flush(scope)
        return false
      end

      scope.pending << job
      if scope.deferrable.include?(job.class.name)
        job.successfully_enqueued = true
      else
        flush(scope)
      end
      true
    end

    def bulk_insertable?(job)
      job.queue_adapter.respond_to?(:enqueue_all) && !job.class.enqueue_after_transaction_commit
    end

    def run_scope(scope)
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = scope
      result = yield
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = nil
      flush(scope)
      result
    rescue Exception # rubocop:disable Lint/RescueException -- re-raised; only flushes what callers already enqueued
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = nil
      flush_after_failure(scope)
      raise
    end

    def flush(scope)
      jobs = scope.pending.dup
      scope.pending.clear
      return if jobs.empty?

      jobs.each { |job| job.successfully_enqueued = false }
      write_with_callbacks(jobs) { |accepted| write(accepted) }
    end

    def flush_after_failure(scope)
      flush(scope)
    rescue StandardError => e
      Rails.logger.error("[BulkJobEnqueue] Flush after failure raised #{e.class}: #{e.message}")
    end

    # Nests each job's enqueue callbacks around a single bulk write. A job
    # whose before_enqueue callback halts the chain is left out of the write,
    # exactly like a halted perform_later.
    def write_with_callbacks(jobs, accepted = [], &write)
      return write.call(accepted) if jobs.empty?

      job, *rest = jobs
      written = false
      job.send(:run_callbacks, :enqueue) do
        written = true
        write_with_callbacks(rest, accepted + [ job ], &write)
      end
      write_with_callbacks(rest, accepted, &write) unless written
    end

    def write(jobs)
      jobs.group_by(&:queue_adapter).each do |adapter, group|
        scheduled_at = group.to_h { |job| [ job, job.scheduled_at ] }
        begin
          adapter.enqueue_all(group)
        rescue ActiveRecord::ActiveRecordError, ActiveJob::EnqueueError => e
          Rails.logger.warn("[BulkJobEnqueue] Bulk enqueue failed (#{e.class}); enqueuing #{group.size} jobs one by one")
          group.each { |job| enqueue_individually(job, scheduled_at.fetch(job)) }
        end
      end
    end

    def enqueue_individually(job, scheduled_at)
      job.scheduled_at = scheduled_at
      job.successfully_enqueued = false
      job.send(:_raw_enqueue)
    end

    # Prepended to ActiveJob::Base so perform_later inside a collect block is
    # routed through the active scope.
    module JobExtension
      private

      def raw_enqueue
        scope = BulkJobEnqueue.current
        return super unless scope && BulkJobEnqueue.capture(self, scope)

        self
      end
    end
  end
end

# Route perform_later through the active collect scope, if any.
ActiveSupport.on_load(:active_job) do
  prepend Collavre::BulkJobEnqueue::JobExtension unless self < Collavre::BulkJobEnqueue::JobExtension
end
