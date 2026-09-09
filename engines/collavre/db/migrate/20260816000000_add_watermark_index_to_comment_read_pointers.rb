class AddWatermarkIndexToCommentReadPointers < ActiveRecord::Migration[8.1]
  # Both receipt paths — rendering a page and repainting after a read — select a
  # creative's pointers by watermark range. The existing indexes are keyed by
  # user first, so those range scans read every pointer row on the creative and
  # filtered in memory. Pointer rows are now per user *and* per topic, so that
  # set grows multiplicatively.
  disable_ddl_transaction!

  def up
    add_index :comment_read_pointers, %i[creative_id last_read_comment_id],
      name: index_name, if_not_exists: true, algorithm: concurrent_algorithm
  end

  def down
    remove_index :comment_read_pointers, name: index_name, if_exists: true, algorithm: concurrent_algorithm
  end

  private

  def index_name
    "index_comment_read_pointers_on_creative_and_watermark"
  end

  def concurrent_algorithm
    :concurrently if connection.adapter_name.match?(/postgres/i)
  end
end
