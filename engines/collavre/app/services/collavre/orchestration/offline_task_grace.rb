# frozen_string_literal: true

module Collavre
  module Orchestration
    # Persist the disconnect deadline on each turn. A timer from an older
    # disconnect must not shorten a later connection's reconnect grace.
    module OfflineTaskGrace
      KEY = "offline_grace_until"
      STATUSES = %w[queued pending running delegated].freeze

      def self.tasks_for(agent, session_id = nil)
        tasks = Task.where(agent_id: agent.id, status: STATUSES)
        return tasks if session_id.blank?

        topic_ids = Topic.where(primary_agent_id: agent.id, session_id: session_id).select(:id)
        tasks.where(topic_id: topic_ids)
      end

      def self.disconnected!(tasks)
        deadline = CancelOfflineDelegatedTasksJob::GRACE_SECONDS.seconds.from_now
        tasks.find_each { |task| write_deadline(task, deadline) }
      end

      def self.connected!(agent, session_id)
        other_sessions = Topic.where(primary_agent_id: agent.id).where.not(session_id: [ nil, "", session_id ].compact).select(:id)
        tasks = Task.where(agent_id: agent.id, status: STATUSES + [ "suspended" ])
        tasks.where(topic_id: nil).or(tasks.where.not(topic_id: other_sessions))
          .find_each { |task| write_deadline(task, nil) }
      end

      def self.deadline(task)
        task.with_lock do
          value = task.trigger_event_payload&.[](KEY)
          return Time.iso8601(value) if value.present?

          deadline = CancelOfflineDelegatedTasksJob::GRACE_SECONDS.seconds.from_now
          write_deadline(task, deadline)
          deadline
        end
      end

      def self.write_deadline(task, deadline)
        task.with_lock do
          payload = (task.trigger_event_payload || {}).except(KEY)
          payload[KEY] = deadline.iso8601(6) if deadline
          task.update!(trigger_event_payload: payload)
        end
      end
    end
  end
end
