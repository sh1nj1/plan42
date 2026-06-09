class CreateOpenclawProcessedAiRuns < ActiveRecord::Migration[8.1]
  # Cross-process idempotency for OpenClaw Gateway runs, owned entirely by the
  # collavre_openclaw engine so the run concept never leaks onto the
  # general-purpose comments table or the core collavre engine.
  #
  # The Gateway broadcasts a run's events to every connection (one per Rails/job
  # process). Only the process that issued chat.send knows the runId; every other
  # process classifies the same final event as "proactive". A unique run_id row
  # guarantees at most one comment per run across all processes and reconnects.
  #
  # comment_id points at the canonical (activity-logged) comment when one
  # survives. ON DELETE SET NULL keeps the run row as a durable tombstone after
  # the comment is destroyed (e.g. the review workflow folds a reply into its
  # quoted comment), so a later proactive re-delivery is still recognized as
  # already-handled. A comment reviewed N times spans N runs — one row each.
  def change
    create_table :openclaw_processed_ai_runs do |t|
      t.string :run_id, null: false
      t.references :comment, null: true, foreign_key: { on_delete: :nullify }

      t.timestamps
    end

    add_index :openclaw_processed_ai_runs, :run_id, unique: true
  end
end
