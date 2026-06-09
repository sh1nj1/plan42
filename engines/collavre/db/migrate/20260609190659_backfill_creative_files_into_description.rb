class BackfillCreativeFilesIntoDescription < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Description HTML is now the source of truth for creative.files (see
  # Collavre::Creative::Describable#reconcile_description_attachments). Existing
  # creatives may have blobs attached to creative.files that are NOT referenced
  # in their description (legacy MCP/console attaches). Embed those orphan blobs
  # into the description so the first reconcile-driven save does not detach them.
  #
  # Idempotent: re-running embeds nothing already referenced. Non-destructive:
  # only ADDS embed nodes; the down migration is a no-op.
  def up
    Collavre::Creative.reset_column_information
    Collavre::Creative.where.not(description: nil).find_each(batch_size: 200) do |creative|
      next unless creative.files.attached?

      Collavre::AttachmentBackfill.embed_orphans!(creative)
    end
  end

  def down
    # No-op: embedded media nodes are non-destructive and idempotent.
  end
end
