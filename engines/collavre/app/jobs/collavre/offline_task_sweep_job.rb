# frozen_string_literal: true

module Collavre
  # ActionCable process crashes do not call unsubscribed. A session topic
  # requires its own session even when siblings still serve shared topics.
  class OfflineTaskSweepJob < ApplicationJob
    queue_as :default

    def perform
      tasks = Task.where(status: Orchestration::OfflineTaskGrace::STATUSES)
        .where(updated_at: ..CancelOfflineDelegatedTasksJob::GRACE_SECONDS.seconds.ago)
      tasks.distinct.pluck(:agent_id).each do |agent_id|
        agent = User.find_by(id: agent_id)
        next unless agent&.claude_channel_agent?

        agent.with_lock { recover_offline(agent) }
        Orchestration::AgentRecoveryTrigger.call(agent.reload)
      end
    end

    private

    def recover_offline(agent)
      live = AgentSubscription.live.where(agent_id: agent.id)
      if live.empty?
        schedule_suspension(agent)
      else
        topics = Topic.where(id: Orchestration::OfflineTaskGrace.tasks_for(agent).select(:topic_id), primary_agent_id: agent.id)
        topics.where.not(session_id: [ nil, "" ]).pluck(:session_id).each do |session_id|
          schedule_suspension(agent, session_id) unless live.where(session_id: session_id).exists?
        end
      end
    end

    def schedule_suspension(agent, session_id = nil)
      deadlines = Orchestration::OfflineTaskGrace.tasks_for(agent, session_id)
        .map { |task| Orchestration::OfflineTaskGrace.deadline(task) }
      return if deadlines.empty?

      CancelOfflineDelegatedTasksJob.set(wait_until: deadlines.min)
        .perform_later(agent.id, nil, session_id)
    end
  end
end
