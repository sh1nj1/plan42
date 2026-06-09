class CreateProcessedAiRuns < ActiveRecord::Migration[8.1]
  # Durable record of OpenClaw Gateway runs that have already produced a visible
  # comment, decoupled from comment lifecycle.
  #
  # comments.openclaw_run_id marks the surviving comment for a run, but it can
  # only hold ONE run per comment. In the review workflow an agent reply is
  # folded into the quoted comment and the placeholder destroyed; a comment
  # reviewed N times therefore spans N runs but has a single run_id slot, so all
  # but the first run lose their dedup marker. This tombstone records every such
  # run independently so a later proactive re-delivery is still recognized as
  # already-handled and suppressed.
  def change
    create_table :processed_ai_runs do |t|
      t.string :run_id, null: false

      t.timestamps
    end

    add_index :processed_ai_runs, :run_id, unique: true
  end
end
