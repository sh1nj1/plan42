# frozen_string_literal: true

require "digest"
require "monitor"

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

        with_key_lock(key, &block)
      end

      def with_repository_name_lock(full_name, &block)
        normalized_name = full_name.to_s.downcase
        raise ArgumentError, "repository full name is required" if normalized_name.blank?

        with_key_lock("name:#{normalized_name}", &block)
      end

      private

      def with_key_lock(key, &block)
        if postgres?
          with_postgres_lock(key, &block)
        else
          # SQLite is used by tests and the single-process desktop app. Its
          # adapter has no advisory-lock primitive, so use the process boundary.
          with_process_lock(key, &block)
        end
      end

      def postgres?
        CollavreGithub::RepositoryLink.connection.adapter_name.casecmp?("PostgreSQL")
      end

      def with_postgres_lock(key)
        CollavreGithub::RepositoryLink.connection_pool.with_connection do |connection|
          advisory_key = advisory_lock_key(key)
          # Schedule the matching unlock before asking PostgreSQL to acquire.
          # If an asynchronous exception lands after PostgreSQL grants the lock
          # but before the adapter returns, the ensure still releases it rather
          # than returning a locked session to the connection pool.
          unlock_required = true
          connection.select_value("SELECT pg_advisory_lock(#{connection.quote(advisory_key)})")
          yield
        ensure
          if unlock_required
            connection.select_value("SELECT pg_advisory_unlock(#{connection.quote(advisory_key)})")
          end
        end
      end

      def advisory_lock_key(key)
        Digest::SHA256.digest("#{LOCK_PURPOSE}:#{key}").unpack1("q>")
      end

      def with_process_lock(key)
        mutex = register_mutex(key)
        mutex.synchronize { yield }
      ensure
        unregister_mutex(key, mutex) if mutex
      end

      def register_mutex(key)
        @mutex_registry_guard.synchronize do
          entry = (@mutex_registry[key] ||= { mutex: Monitor.new, users: 0 })
          entry[:users] += 1
          entry[:mutex]
        end
      end

      def unregister_mutex(key, mutex)
        @mutex_registry_guard.synchronize do
          entry = @mutex_registry[key]
          return unless entry && entry[:mutex].equal?(mutex)

          entry[:users] -= 1
          @mutex_registry.delete(key) if entry[:users].zero?
        end
      end
    end
  end
end
