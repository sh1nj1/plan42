class MigrateLinkedCreativeChildrenToOrigin < ActiveRecord::Migration[8.1]
  def up
    # Find all creatives that are children of a Linked Creative (a creative with an origin_id)
    # and update their parent to be the origin of that Linked Creative.

    # We use find_each to avoid loading all records into memory
    Creative.where(parent_id: Creative.where.not(origin_id: nil).select(:id)).find_each do |child|
      # child.parent is the Linked Creative
      # child.parent.origin is the Origin Creative
      # We want child.parent to become child.parent.origin

      # Note: We use update_column to avoid triggering callbacks/validations if necessary,
      # but update! is safer if we want to ensure data integrity.
      # However, since we added a callback that does exactly this, saving might trigger it anyway.
      # Let's use update_columns for speed and to bypass the callback we just added (though it would do the same thing).

      if child.parent && child.parent.origin
        child.update_columns(parent_id: child.parent.origin_id)
      end
    end
  end

  def down
    # This migration is irreversible because we lose the information of which Linked Creative
    # the child was originally attached to.
    raise ActiveRecord::IrreversibleMigration
  end
end
