class AddOpenclawRunIdToComments < ActiveRecord::Migration[8.1]
  # Gateway run identifier used as a cross-process idempotency key.
  #
  # OpenClaw broadcasts the same chat run's events to every Gateway
  # connection (one per Rails/job process). Only the process that issued
  # chat.send knows the runId; every other process classifies the run's
  # final event as "proactive" and creates a duplicate comment. Persisting
  # the runId — and a partial unique index on it — guarantees at most one
  # comment per run across all processes and reconnects.
  def change
    add_column :comments, :openclaw_run_id, :string

    add_index :comments, :openclaw_run_id,
              unique: true,
              where: "openclaw_run_id IS NOT NULL",
              name: "index_comments_on_openclaw_run_id"
  end
end
