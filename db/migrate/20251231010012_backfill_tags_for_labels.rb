class BackfillTagsForLabels < ActiveRecord::Migration[8.1]
  def up
    Label.where.not(creative_id: nil).find_each do |label|
      next if Tag.exists?(label_id: label.id, creative_id: label.creative_id)

      Tag.create!(label_id: label.id, creative_id: label.creative_id)
    end
  end

  def down
    # No-op or potentially delete tags created by this migration
    # Since tags might have been created manually later, it's safer to avoid bulk deletion
    # unless we track which ones were created here.
  end
end
