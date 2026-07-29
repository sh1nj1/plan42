# frozen_string_literal: true

require "digest"

module CollavreGithub
  # Serializes link persistence and remote webhook mutation for one stable
  # GitHub repository identity. Without this boundary, two creatives attaching
  # a previously unseen repository can each provision from an uncommitted link
  # and publish different secrets (or create duplicate hooks).
  class RepositoryProvisioningLock
    LOCK_PURPOSE = "collavre_github:repository_provisioning".freeze

    @mutex_registry_guard = Mutex.new
    @mutex_registry = {}

    class << self
      def with_lock(repository_id, &block)
        key = repository_id.to_s
        raise ArgumentError, "repository_id is required" if key.blank?

        if postgres?
          with_postgres_lock(key, &block)
        else
          # SQLite is used by tests and the single-process desktop app. Its
          # adapter has no advisory-lock primitive, so use the process boundary.
          with_process_lock(key, &block)
        end
      end

      private

      def postgres?
        CollavreGithub::RepositoryLink.connection.adapter_name.casecmp?("PostgreSQL")
      end

      def with_postgres_lock(repository_id)
        CollavreGithub::RepositoryLink.connection_pool.with_connection do |connection|
          key = advisory_lock_key(repository_id)
          # Schedule the matching unlock before asking PostgreSQL to acquire.
          # If an asynchronous exception lands after PostgreSQL grants the lock
          # but before the adapter returns, the ensure still releases it rather
          # than returning a locked session to the connection pool.
          unlock_required = true
          connection.select_value("SELECT pg_advisory_lock(#{connection.quote(key)})")
          yield
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{connection.quote(key)})") if unlock_required
        end
      end

      def advisory_lock_key(repository_id)
        Digest::SHA256.digest("#{LOCK_PURPOSE}:#{repository_id}").unpack1("q>")
      end

      def with_process_lock(repository_id)
        mutex = register_mutex(repository_id)
        mutex.synchronize { yield }
      ensure
        unregister_mutex(repository_id, mutex) if mutex
      end

      def register_mutex(repository_id)
        @mutex_registry_guard.synchronize do
          entry = (@mutex_registry[repository_id] ||= { mutex: Mutex.new, users: 0 })
          entry[:users] += 1
          entry[:mutex]
        end
      end

      def unregister_mutex(repository_id, mutex)
        @mutex_registry_guard.synchronize do
          entry = @mutex_registry[repository_id]
          return unless entry && entry[:mutex].equal?(mutex)

          entry[:users] -= 1
          @mutex_registry.delete(repository_id) if entry[:users].zero?
        end
      end
    end
  end
end
