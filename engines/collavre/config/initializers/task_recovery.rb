# frozen_string_literal: true

if defined?(SolidQueue)
  SolidQueue.on_worker_start do
    Rails.application.executor.wrap { Collavre::RecoverInterruptedTasksJob.perform_later }
  end
  SolidQueue.on_worker_stop do |worker|
    Rails.application.executor.wrap do
      Collavre::RecoverInterruptedTasksJob.set(wait: SolidQueue.shutdown_timeout + 1.second).perform_later
    end
  ensure
    # Stop hooks run before pool drain and process deregistration. Do not let
    # deregistration release a still-executing AI job back to ready: a second
    # worker could take it while the original provider call is still running.
    # The supervisor retains its existing timeout/forced-exit behavior. If it
    # kills this process, the claim remains for process-failure recovery.
    # Wait outside the Rails executor and pass nil for thread AND fiber pools.
    if worker.queues.any? { |queue| File.fnmatch?(queue, "ai_agents") }
      worker.pool.shutdown
      worker.pool.wait_for_termination(nil)
    end
  end
end

Rails.application.config.to_prepare do
  if defined?(SolidQueue::FailedExecution)
    SolidQueue::FailedExecution.prepend(Collavre::Orchestration::SolidQueueRetryRecovery)
    SolidQueue::FailedExecution.singleton_class.prepend(Collavre::Orchestration::SolidQueueRetryRecovery::Bulk)
  end
end
