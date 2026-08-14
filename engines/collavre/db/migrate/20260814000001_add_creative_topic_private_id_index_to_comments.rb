class AddCreativeTopicPrivateIdIndexToComments < ActiveRecord::Migration[8.1]
  # Badge fanout counts per-topic suffixes after a reader watermark. The former
  # creative/private/id index still needs to scan every newer topic in a busy
  # creative, while this index lets the database seek directly to that topic's
  # suffix.
  disable_ddl_transaction!

  def up
    options = { name: index_name, if_not_exists: true }

    if postgresql?
      options.merge!(where: "private = false", algorithm: :concurrently)
      add_index :comments, %i[creative_id topic_id id], **options
    else
      add_index :comments, %i[creative_id private topic_id id], **options
    end
  end

  def down
    options = { name: index_name, algorithm: concurrent_algorithm, if_exists: true }
    remove_index :comments, **options
  end

  private

  def index_name
    "index_comments_on_creative_topic_private_and_id"
  end

  def postgresql?
    connection.adapter_name.match?(/postgres/i)
  end

  def concurrent_algorithm
    :concurrently if postgresql?
  end
end
