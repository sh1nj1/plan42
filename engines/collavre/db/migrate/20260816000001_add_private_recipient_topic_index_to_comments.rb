class AddPrivateRecipientTopicIndexToComments < ActiveRecord::Migration[8.1]
  # Badge fanout asks which topics hold private comments for each recipient. The
  # existing private index is keyed by topic before recipient, so answering that
  # per user meant scanning every private comment on the creative.
  disable_ddl_transaction!

  RECIPIENT_COLUMNS = %i[user_id approver_id].freeze

  def up
    RECIPIENT_COLUMNS.each do |recipient_column|
      add_index :comments, index_columns(recipient_column), **index_options(recipient_column).merge(if_not_exists: true)
    end
  end

  def down
    RECIPIENT_COLUMNS.each do |recipient_column|
      remove_index :comments, name: index_name(recipient_column), if_exists: true, algorithm: concurrent_algorithm
    end
  end

  private

  # On PostgreSQL the predicate carries `private`, so it stays out of the key.
  def index_columns(recipient_column)
    return [ :creative_id, recipient_column, :topic_id ] if postgresql?

    [ :creative_id, :private, recipient_column, :topic_id ]
  end

  def index_options(recipient_column)
    options = { name: index_name(recipient_column) }
    return options unless postgresql?

    options.merge(where: "private = true", algorithm: :concurrently)
  end

  def index_name(recipient_column)
    "index_comments_on_creative_private_#{recipient_column}_and_topic"
  end

  def postgresql?
    connection.adapter_name.match?(/postgres/i)
  end

  def concurrent_algorithm
    :concurrently if postgresql?
  end
end
