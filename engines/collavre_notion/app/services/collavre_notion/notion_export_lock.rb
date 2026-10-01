module CollavreNotion
  # A session lock avoids rolling back progress when a later remote request fails.
  class NotionExportLock
    def self.synchronize(account_id, &block)
      NotionAccount.connection_pool.with_connection do |connection|
        if connection.adapter_name == "PostgreSQL"
          postgres_lock(connection, account_id, &block)
        else
          file_lock(connection, account_id, &block)
        end
      end
    end

    def self.postgres_lock(connection, account_id)
      key = Digest::SHA256.digest("collavre_notion:export:#{account_id}").unpack1("q>")
      begin
        connection.select_value("SELECT pg_advisory_lock(#{connection.quote(key)})")
        yield
      ensure
        connection.select_value("SELECT pg_advisory_unlock(#{connection.quote(key)})")
      end
    end

    def self.file_lock(connection, account_id)
      database = File.expand_path(connection.pool.db_config.database, Rails.root)
      File.open("#{database}.notion-#{account_id}.lock", File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        begin
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end
  end
end
