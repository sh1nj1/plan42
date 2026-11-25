require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260922113000_add_emoji_comment_index_to_comment_reactions")

class AddEmojiCommentIndexToCommentReactionsTest < ActiveSupport::TestCase
  test "disables the DDL transaction for concurrent index operations" do
    assert AddEmojiCommentIndexToCommentReactions.disable_ddl_transaction
  end

  test "creates and removes the PostgreSQL index concurrently" do
    assert_index_operations "PostgreSQL", :concurrently
  end

  test "creates and removes the SQLite index without a concurrent algorithm" do
    assert_index_operations "SQLite", nil
  end

  private

  def assert_index_operations(adapter, algorithm)
    migration = AddEmojiCommentIndexToCommentReactions.new
    connection = Struct.new(:adapter_name).new(adapter)
    calls = []
    %i[add_index remove_index].each do |operation|
      migration.define_singleton_method(operation) do |table, columns, **options|
        calls << [ operation, table, columns, options ]
      end
    end

    migration.stub(:connection, connection) do
      migration.up
      migration.down
    end

    assert_equal [
      [ :add_index, :comment_reactions, [ :emoji, :comment_id ], { algorithm: algorithm } ],
      [ :remove_index, :comment_reactions, [ :emoji, :comment_id ], { algorithm: algorithm } ]
    ], calls
  end
end
