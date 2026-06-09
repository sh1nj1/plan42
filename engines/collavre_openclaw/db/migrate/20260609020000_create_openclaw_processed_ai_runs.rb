class CreateOpenclawProcessedAiRuns < ActiveRecord::Migration[8.1]
  # Unique run_id guarantees at most one comment per Gateway run across all
  # processes and reconnects. ON DELETE SET NULL keeps the row as a tombstone
  # after its comment is destroyed (review-fold), so re-deliveries stay deduped.
  def change
    create_table :openclaw_processed_ai_runs do |t|
      t.string :run_id, null: false
      t.references :comment, null: true, foreign_key: { on_delete: :nullify }

      t.timestamps
    end

    add_index :openclaw_processed_ai_runs, :run_id, unique: true
  end
end
