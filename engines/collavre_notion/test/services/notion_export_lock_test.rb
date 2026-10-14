require_relative "../test_helper"

class NotionExportLockTest < ActiveSupport::TestCase
  test "file lock releases after failure and can be reacquired" do
    assert_raises(RuntimeError) do
      CollavreNotion::NotionExportLock.synchronize(123) { raise "failed" }
    end
    assert_equal :done, CollavreNotion::NotionExportLock.synchronize(123) { :done }
  end

  test "SQLite lock excludes another file descriptor while held" do
    CollavreNotion::NotionExportLock.synchronize(123) do
      database = File.expand_path(CollavreNotion::NotionAccount.connection_pool.db_config.database, Rails.root)
      File.open("#{database}.notion-123.lock", File::RDWR) do |other|
        assert_equal false, other.flock(File::LOCK_EX | File::LOCK_NB)
      end
    end
  end

  test "PostgreSQL adapter selects a session lock" do
    connection = Minitest::Mock.new
    connection.expect(:adapter_name, "PostgreSQL")
    connection.expect(:quote, "123", [ Integer ])
    connection.expect(:select_value, nil, [ "SELECT pg_advisory_lock(123)" ])
    connection.expect(:quote, "123", [ Integer ])
    connection.expect(:select_value, nil, [ "SELECT pg_advisory_unlock(123)" ])
    pool = Object.new
    pool.define_singleton_method(:with_connection) { |&block| block.call(connection) }
    CollavreNotion::NotionAccount.stub(:connection_pool, pool) do
      assert_equal :done, CollavreNotion::NotionExportLock.synchronize(1) { :done }
    end
    assert connection.verify
  end

  test "PostgreSQL session lock releases even when work fails" do
    connection = Minitest::Mock.new
    connection.expect(:quote, "123", [ Integer ])
    connection.expect(:select_value, nil, [ "SELECT pg_advisory_lock(123)" ])
    connection.expect(:quote, "123", [ Integer ])
    connection.expect(:select_value, nil, [ "SELECT pg_advisory_unlock(123)" ])
    assert_raises(RuntimeError) do
      CollavreNotion::NotionExportLock.postgres_lock(connection, 1) { raise "failed" }
    end
    connection.verify
  end
end
