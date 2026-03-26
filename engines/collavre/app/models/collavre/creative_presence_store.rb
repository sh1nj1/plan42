module Collavre
  class CreativePresenceStore
    KEY_PREFIX = "creative_presence:"
    LOCK_TTL = 2 # seconds
    PRESENCE_TTL = 10 # minutes

    def self.add(root_id, user_id)
      with_lock(root_id) do
        ids = list(root_id)
        unless ids.include?(user_id)
          ids << user_id
        end
        Rails.cache.write(key(root_id), ids, expires_in: PRESENCE_TTL.minutes)
        ids
      end
    end

    def self.remove(root_id, user_id)
      with_lock(root_id) do
        ids = list(root_id)
        if ids.delete(user_id)
          Rails.cache.write(key(root_id), ids, expires_in: PRESENCE_TTL.minutes)
        end
        ids
      end
    end

    def self.list(root_id)
      Rails.cache.read(key(root_id)) || []
    end

    def self.key(root_id)
      "#{KEY_PREFIX}#{root_id}"
    end

    def self.lock_key(root_id)
      "#{KEY_PREFIX}lock:#{root_id}"
    end

    # Simple spin-lock using cache. Prevents race conditions in multi-process environments.
    def self.with_lock(root_id, &block)
      lk = lock_key(root_id)
      # Try to acquire lock (expires after LOCK_TTL to avoid deadlocks)
      10.times do
        if Rails.cache.write(lk, true, unless_exist: true, expires_in: LOCK_TTL.seconds)
          begin
            return block.call
          ensure
            Rails.cache.delete(lk)
          end
        end
        sleep(0.05)
      end
      # Fallback: proceed without lock (better than blocking forever)
      block.call
    end
  end
end
