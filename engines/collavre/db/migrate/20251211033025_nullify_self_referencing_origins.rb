class NullifySelfReferencingOrigins < ActiveRecord::Migration[8.1]
  def up
    Creative.where("origin_id = id").update_all(origin_id: nil)
  end

  def down
    # Irreversible as we cannot know which ones were self-referencing if valid data also had nil
  end
end
