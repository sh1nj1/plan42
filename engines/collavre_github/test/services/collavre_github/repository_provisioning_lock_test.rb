require_relative "../../test_helper"

module CollavreGithub
  class RepositoryProvisioningLockTest < ActiveSupport::TestCase
    test "serializes callers for the same repository" do
      first_entered = Queue.new
      release_first = Queue.new
      events = Queue.new

      first = Thread.new do
        RepositoryProvisioningLock.with_lock(101) do
          events << :first_entered
          first_entered << true
          release_first.pop
          events << :first_leaving
        end
      end
      first_entered.pop

      second = Thread.new do
        RepositoryProvisioningLock.with_lock(101) do
          events << :second_entered
        end
      end

      assert_equal :first_entered, events.pop
      assert events.empty?, "second caller entered before the first released the repository lock"

      release_first << true
      [ first, second ].each(&:join)

      assert_equal :first_leaving, events.pop
      assert_equal :second_entered, events.pop
    ensure
      release_first << true if first&.alive?
      [ first, second ].compact.each(&:join)
    end

    test "does not serialize different repositories" do
      first_entered = Queue.new
      release_first = Queue.new
      second_entered = Queue.new

      first = Thread.new do
        RepositoryProvisioningLock.with_lock(101) do
          first_entered << true
          release_first.pop
        end
      end
      first_entered.pop

      second = Thread.new do
        RepositoryProvisioningLock.with_lock(202) { second_entered << true }
      end

      assert second_entered.pop
    ensure
      release_first << true if first&.alive?
      [ first, second ].compact.each(&:join)
    end

    test "serializes repository names case-insensitively" do
      first_entered = Queue.new
      release_first = Queue.new
      events = Queue.new

      first = Thread.new do
        RepositoryProvisioningLock.with_repository_name_lock("Owner/Repo") do
          events << :first_entered
          first_entered << true
          release_first.pop
          events << :first_leaving
        end
      end
      first_entered.pop

      second = Thread.new do
        RepositoryProvisioningLock.with_repository_name_lock("owner/repo") do
          events << :second_entered
        end
      end

      assert_equal :first_entered, events.pop
      assert events.empty?, "case-variant repository names entered the lock concurrently"

      release_first << true
      [ first, second ].each(&:join)

      assert_equal :first_leaving, events.pop
      assert_equal :second_entered, events.pop
    ensure
      release_first << true if first&.alive?
      [ first, second ].compact.each(&:join)
    end

    test "allows a repository name lock to be reacquired by the same thread" do
      entered = []

      RepositoryProvisioningLock.with_repository_name_lock("Owner/Repo") do
        RepositoryProvisioningLock.with_repository_name_lock("owner/repo") do
          entered << true
        end
      end

      assert_equal [ true ], entered
    end

    test "releases a postgres lock when acquisition result handling raises" do
      connection = Class.new do
        attr_reader :queries

        def initialize
          @queries = []
        end

        def adapter_name
          "PostgreSQL"
        end

        def quote(value)
          value.to_s
        end

        def select_value(query)
          queries << query
          raise "interrupted after server acquisition" if queries.one?

          true
        end
      end.new
      pool = Struct.new(:connection) do
        def with_connection
          yield connection
        end
      end.new(connection)

      CollavreGithub::RepositoryLink.stub(:connection, connection) do
        CollavreGithub::RepositoryLink.stub(:connection_pool, pool) do
          error = assert_raises(RuntimeError) do
            RepositoryProvisioningLock.with_lock(101) { flunk("lock body must not run") }
          end
          assert_equal "interrupted after server acquisition", error.message
        end
      end

      assert_match(/\ASELECT pg_advisory_lock\(-?\d+\)\z/, connection.queries.first)
      assert_match(/\ASELECT pg_advisory_unlock\(-?\d+\)\z/, connection.queries.second)
    end
  end
end
