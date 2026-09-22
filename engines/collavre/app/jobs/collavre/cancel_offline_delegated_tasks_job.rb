# frozen_string_literal: true

module Collavre
  # Preserve interrupted channel work after the reconnect grace period. The
  # historical job name is retained for jobs already persisted in Solid Queue.
  class CancelOfflineDelegatedTasksJob < ApplicationJob
    queue_as :default

    GRACE_SECONDS = 30

    def perform(agent_id, expected_token, session_id = nil)
      agent = User.find_by(id: agent_id)
      return unless agent&.claude_channel_agent?

      # Presence and suspension must serialize with subscribe/unsubscribe. A
      # reconnect either prevents suspension or observes it and schedules resume.
      deferred_until = nil
      agent.with_lock do
        AgentSubscription.reap_stale!(agent.id)
        tasks = offline_tasks(agent, expected_token, session_id)
        next unless tasks

        deferred_until = tasks.map { |task| Orchestration::OfflineTaskGrace.deadline(task) }.max
        next if deferred_until && deferred_until > Time.current

        deferred_until = nil
        %w[queued pending running delegated].each do |status|
          tasks.where(status: status).find_each do |task|
            Orchestration::TaskResumer.suspend!(task, reason: "agent_offline")
          end
        end
      end
      self.class.set(wait_until: deferred_until).perform_later(agent_id, expected_token, session_id) if deferred_until
    end

    private

    def offline_tasks(agent, expected_token, session_id)
      live = AgentSubscription.live.where(agent_id: agent.id)
      if session_id.present?
        return if live.where(session_id: session_id).exists?
        topic = Topic.find_by(primary_agent_id: agent.id, session_id: session_id)
        return unless topic

        Task.where(agent_id: agent.id, topic_id: topic.id, status: %w[queued pending running delegated])
      else
        return if live.exists?
        return if expected_token.present? && agent.routing_subscription_token.present? &&
          agent.routing_subscription_token != expected_token

        Task.where(agent_id: agent.id, status: %w[queued pending running delegated])
      end
    end
  end
end
