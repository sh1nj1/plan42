class RefactorLabels < ActiveRecord::Migration[8.1]
  def up
    # Data migration: Create Creatives for Labels that don't have one
    Label.where(creative_id: nil).find_each do |label|
      next if label.name.blank?

      # Create a new Creative using the Label's name and owner
      creative = Creative.create!(
        description: label.name,
        user_id: label.owner_id,
        progress: 0.0 # Default value
      )

      label.update!(creative_id: creative.id)
    end

    # Schema changes
    change_column_null :labels, :creative_id, false
    remove_column :labels, :name
  end

  def down
    add_column :labels, :name, :string
    change_column_null :labels, :creative_id, true

    # Optional: We could attempt to restore names from creatives, but
    # since we can't be sure which creative was created specifically for the label migration vs manual,
    # strictly speaking the down migration might just restore schema.
    # But for completeness let's try to put creative description back to name if it matches?
    # For now, just restoring schema is safer.
  end
end
