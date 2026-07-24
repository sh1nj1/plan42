class AddDoneStateIdToLinearProjectLinks < ActiveRecord::Migration[8.0]
  # The Linear workflow-state UUID that represents "done" for this linked
  # project. Chosen by the admin (combobox, default "Completed") at link time.
  # Nullable: links created before this feature — or teams with no completed
  # state — simply have no completion mapping (the sync no-ops both ways).
  def change
    add_column :linear_project_links, :done_state_id, :string
  end
end
