class RemoveWorkflowColumnsFromTasks < ActiveRecord::Migration[8.1]
  # The /work command and its WorkflowExecutor are gone, and they were the only
  # producers of parent_task_id / workflow_context / workflow_state / retry_count.
  # Nothing reads these columns anymore, so drop them.

  IN_FLIGHT_STATUSES = %w[pending queued running delegated pending_approval].freeze

  # AiAgentJob reserves the agent's ResourceTracker slot under task.id once the
  # job starts, so only these statuses can still hold one; pending and queued
  # never reached reserve!. release! on an unreserved id is a no-op anyway.
  RESERVED_STATUSES = %w[running delegated pending_approval].freeze

  def up
    cancel_in_flight_workflow_tasks

    remove_foreign_key :tasks, :tasks, column: :parent_task_id, if_exists: true
    remove_column :tasks, :parent_task_id, :integer
    remove_column :tasks, :workflow_context, :text
    remove_column :tasks, :workflow_state, :json
    remove_column :tasks, :retry_count, :integer, default: 0, null: false
  end

  def down
    add_column :tasks, :parent_task_id, :integer
    add_column :tasks, :workflow_context, :text
    add_column :tasks, :workflow_state, :json
    add_column :tasks, :retry_count, :integer, default: 0, null: false
    add_index :tasks, :parent_task_id
    add_foreign_key :tasks, :tasks, column: :parent_task_id, on_delete: :nullify
  end

  private

  # Any workflow still mid-flight loses the state that would let it advance.
  # Cancel those rows before the columns disappear so they cannot linger as
  # permanently "running" tasks holding a topic slot.
  def cancel_in_flight_workflow_tasks
    rows = select_all(<<~SQL.squish).to_a
      SELECT id, agent_id, topic_id, creative_id, status
      FROM tasks
      WHERE status IN (#{quoted_in_flight_statuses})
        AND (parent_task_id IS NOT NULL
             OR trigger_event_name IN ('work_command', 'workflow_subtask'))
    SQL
    return if rows.empty?

    ids = rows.map { |row| row["id"].to_i }.join(", ")
    execute(<<~SQL.squish)
      UPDATE tasks
      SET status = 'cancelled', updated_at = #{connection.quote(Time.current)}
      WHERE id IN (#{ids})
    SQL

    release_slots(rows)
  end

  # A raw UPDATE only settles the row. Every other bulk cancellation in the app
  # (TasksController#cancel, CancelOfflineDelegatedTasksJob, stuck recovery)
  # also hands back the agent's ResourceTracker slot and drains the topic queue,
  # because these tasks were paused with no live worker to run AiAgentJob's
  # ensure-block. Skipping that here would keep a cancelled task counting
  # against the agent's max_concurrent_jobs until the cache entry expires an
  # hour later — long enough, with a limit of 1, to freeze the agent right after
  # deploy. Reaching into app classes from a migration is unusual, but the
  # reservation lives in Rails.cache and there is no SQL equivalent.
  def release_slots(rows)
    return unless defined?(Collavre::Orchestration::ResourceTracker)

    rows.group_by { |row| row["agent_id"] }.each do |agent_id, agent_rows|
      next if agent_id.blank?

      agent = Collavre::User.find_by(id: agent_id)
      next unless agent

      tracker = Collavre::Orchestration::ResourceTracker.for(agent)
      agent_rows.each do |row|
        tracker.release!(row["id"]) if RESERVED_STATUSES.include?(row["status"])
      end
    end

    drain_topics(rows)
  rescue StandardError => e
    # Cache/orchestration cleanup is best effort: stuck recovery still sweeps
    # whatever is left. Never fail the schema change over it.
    say("Slot release after workflow cancellation failed: #{e.class}: #{e.message}")
  end

  # Freeing the slot is only half of it — a waiter queued behind the cancelled
  # holder stays queued until stuck recovery notices, which can take minutes.
  def drain_topics(rows)
    rows.filter_map { |row| [ row["topic_id"], row["creative_id"] ] if row["topic_id"].present? }
        .uniq
        .each do |topic_id, creative_id|
      Collavre::Orchestration::AgentOrchestrator.dequeue_next_for_topic(topic_id, creative_id)
    end
  end

  def quoted_in_flight_statuses
    IN_FLIGHT_STATUSES.map { |status| connection.quote(status) }.join(", ")
  end
end
